defmodule WaggerWeb.OauthCredentialsLive do
  @moduledoc """
  Admin LiveView for managing OAuth provider credentials. Secrets are
  shown as `••••` once set; saving locks the value via Wagger.Secrets.
  """

  use WaggerWeb, :live_view

  alias Wagger.OauthCredentials

  @providers ~w(google github)

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :providers, providers_state())}
  end

  def handle_event("save", %{"provider" => provider, "cred" => params}, socket) do
    secret = effective_secret(provider, params["client_secret"])

    case secret do
      :unset ->
        {:noreply,
         put_flash(socket, :error, "No secret has ever been set; please provide one.")}

      val ->
        case OauthCredentials.upsert(provider, params["client_id"], val) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Saved #{provider} credentials.")
             |> assign(:providers, providers_state())}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save credentials.")}
        end
    end
  end

  defp providers_state do
    Enum.map(@providers, fn p ->
      case OauthCredentials.get(p) do
        {:ok, %{client_id: id}} -> %{provider: p, client_id: id, has_secret: true}
        :error -> %{provider: p, client_id: "", has_secret: false}
      end
    end)
  end

  defp effective_secret(provider, "") do
    case OauthCredentials.get(provider) do
      {:ok, %{client_secret: existing}} -> existing
      :error -> :unset
    end
  end

  defp effective_secret(_provider, secret), do: secret
end
