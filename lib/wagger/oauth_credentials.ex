defmodule Wagger.OauthCredentials do
  @moduledoc """
  Context for OAuth provider credentials.

  Credentials live in the `oauth_provider_credentials` table; the
  `client_secret` is encrypted at rest via `Wagger.Secrets.lock/1`.
  On boot (and after each upsert), `load_into_app_env/0` decrypts and
  publishes credentials to the `:ueberauth` Application environment so
  Ueberauth strategies can read them at request time.
  """

  alias Wagger.Repo
  alias Wagger.OauthCredentials.Credential

  require Logger

  @providers ~w(google github)

  @env_var %{
    "google" => {"GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"},
    "github" => {"GITHUB_OAUTH_CLIENT_ID", "GITHUB_OAUTH_CLIENT_SECRET"}
  }

  @oauth_strategy %{
    "google" => Ueberauth.Strategy.Google.OAuth,
    "github" => Ueberauth.Strategy.Github.OAuth
  }

  @doc """
  Upserts credentials for a provider. Locks the secret with
  `Wagger.Secrets.lock/1`, persists, and refreshes the Application env.
  """
  def upsert(provider, client_id, client_secret)
      when provider in @providers and is_binary(client_id) and is_binary(client_secret) do
    with {:ok, locked} <- Wagger.Secrets.lock(client_secret),
         {:ok, cred} <- do_upsert(provider, client_id, locked),
         :ok <- load_into_app_env() do
      {:ok, cred}
    end
  end

  defp do_upsert(provider, client_id, locked_secret) do
    case Repo.get_by(Credential, provider: provider) do
      nil ->
        %Credential{}
        |> Credential.changeset(%{
          "provider" => provider,
          "client_id" => client_id,
          "client_secret_locked" => locked_secret
        })
        |> Repo.insert()

      existing ->
        existing
        |> Credential.changeset(%{
          "client_id" => client_id,
          "client_secret_locked" => locked_secret
        })
        |> Repo.update()
    end
  end

  @doc """
  Returns `{:ok, %{client_id: ..., client_secret: plaintext}}` for a
  configured provider, or `:error`.
  """
  def get(provider) when provider in @providers do
    case Repo.get_by(Credential, provider: provider) do
      nil ->
        :error

      %Credential{client_id: id, client_secret_locked: locked} ->
        case Wagger.Secrets.unlock(locked) do
          {:ok, plaintext} -> {:ok, %{client_id: id, client_secret: plaintext}}
          _ -> :error
        end
    end
  end

  @doc """
  Pushes all configured providers' credentials into the
  `:ueberauth` Application environment. For providers without DB
  credentials, attempts to seed from env vars (one-time bootstrap).
  Returns `:ok` always.
  """
  def load_into_app_env do
    Enum.each(@providers, &load_provider/1)
    :ok
  end

  defp load_provider(provider) do
    case get(provider) do
      {:ok, %{client_id: id, client_secret: secret}} ->
        publish(provider, id, secret)

      :error ->
        case env_var_creds(provider) do
          {:ok, id, secret} ->
            case Wagger.Secrets.lock(secret) do
              {:ok, locked} ->
                case do_upsert(provider, id, locked) do
                  {:ok, _} -> publish(provider, id, secret)
                  _ -> :ok
                end

              {:error, reason} ->
                Logger.warning(
                  "OAuth env-var bootstrap for #{provider} failed to lock secret " <>
                    "(#{inspect(reason)}); provider remains unconfigured"
                )

                :ok
            end

          :error ->
            :ok
        end
    end
  end

  defp env_var_creds(provider) do
    {id_var, secret_var} = Map.fetch!(@env_var, provider)
    id = System.get_env(id_var)
    secret = System.get_env(secret_var)

    if is_binary(id) and is_binary(secret) and id != "" and secret != "" do
      {:ok, id, secret}
    else
      :error
    end
  end

  defp publish(provider, client_id, client_secret) do
    strategy = Map.fetch!(@oauth_strategy, provider)
    Application.put_env(:ueberauth, strategy, client_id: client_id, client_secret: client_secret)
    :ok
  end

  @doc "Returns true when the provider has stored credentials."
  def provider_configured?(provider) when provider in @providers do
    case get(provider) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
