defmodule Wagger.Accounts do
  @moduledoc """
  Context module for users and authentication.

  Authentication paths:
  - API key (existing)
  - OAuth via linked `oauth_identities` (browser)
  - Local password (browser)
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Accounts.{OauthIdentity, User}

  @username_suffix_bytes 3

  # ----- existing API-key-based functions -----

  @doc """
  Creates a user with a generated API key. Returns
  `{:ok, user, api_key_plaintext}` or `{:error, changeset}`.
  """
  def create_user(attrs \\ %{}) do
    api_key = generate_api_key()
    api_key_hash = hash_api_key(api_key)

    key = if Map.keys(attrs) |> List.first() |> is_atom(), do: :api_key_hash, else: "api_key_hash"
    attrs_with_hash = Map.put(attrs, key, api_key_hash)

    case %User{} |> User.changeset(attrs_with_hash) |> Repo.insert() do
      {:ok, user} -> {:ok, user, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Authenticates a user by raw API key. Returns `{:ok, user}` or `{:error, _}`."
  def authenticate_by_api_key(api_key) do
    hash = hash_api_key(api_key)

    case Repo.get_by(User, api_key_hash: hash) do
      nil -> {:error, Comn.Errors.Registry.error!("wagger.accounts/auth_failed")}
      user -> {:ok, user}
    end
  end

  def list_users, do: Repo.all(User)
  def get_user!(id), do: Repo.get!(User, id)

  def delete_user(%User{username: "admin"}) do
    {:error, Comn.Errors.Registry.error!("wagger.accounts/protected_user")}
  end

  def delete_user(%User{} = user), do: Repo.delete(user)

  def setup_required?, do: Repo.aggregate(User, :count, :id) == 0

  # ----- new functions for OAuth + password auth -----

  @doc """
  Registers a User created via OAuth (or otherwise without an API key).
  Derives a username from the email local-part. Does NOT generate an
  API key. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def register_oauth_user(attrs) when is_map(attrs) do
    email = Map.get(attrs, :email) || Map.get(attrs, "email")
    base_username = derive_username(email)

    final_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("username", available_username(base_username))
      |> Map.put_new("role", "user")

    %User{} |> User.changeset(final_attrs) |> Repo.insert()
  end

  defp derive_username(nil), do: random_username()

  defp derive_username(email) when is_binary(email) do
    [local, _domain] = String.split(email, "@", parts: 2)

    local
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> random_username()
      slug -> slug
    end
  end

  defp available_username(base) do
    case Repo.get_by(User, username: base) do
      nil -> base
      _ -> base <> "-" <> random_suffix()
    end
  end

  defp random_username, do: "user-" <> random_suffix()

  defp random_suffix do
    :crypto.strong_rand_bytes(@username_suffix_bytes)
    |> Base.url_encode64(padding: false)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  @doc "Returns the user with the given email, or nil."
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: User.normalize_email(email))
  end

  @doc """
  Sets a password for the user. Argon2-hashes the plaintext.
  Returns `{:ok, updated_user}` or `{:error, changeset}`.
  Rejects passwords shorter than 12 characters.
  """
  def set_password(%User{} = user, plaintext) when is_binary(plaintext) do
    if String.length(plaintext) < 12 do
      cs =
        user
        |> User.changeset(%{})
        |> Ecto.Changeset.add_error(:password_hash, "must be at least 12 characters")

      {:error, cs}
    else
      hash = Argon2.hash_pwd_salt(plaintext)

      user
      |> User.changeset(%{"password_hash" => hash})
      |> Repo.update()
    end
  end

  @doc """
  Authenticates by email + plaintext password.
  Returns `{:ok, user}` or `{:error, :invalid_credentials}`.
  Constant-time on missing-user.
  """
  def authenticate_by_password(email, plaintext) when is_binary(email) and is_binary(plaintext) do
    case get_user_by_email(email) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{password_hash: nil} ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{password_hash: hash} = user ->
        if Argon2.verify_pass(plaintext, hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Clears the user's password. Refuses if doing so would leave the user
  with no remaining auth method (no linked OAuth identities and no API
  key). Returns `{:ok, user}` or `{:error, ErrorStruct}`.
  """
  def clear_password(%User{} = user) do
    if has_other_auth_method?(user, exclude: :password) do
      user
      |> User.changeset(%{"password_hash" => nil})
      |> Repo.update()
    else
      {:error, Comn.Errors.Registry.error!("wagger.accounts/orphan_account",
        message: "removing this would leave the account with no way to log in"
      )}
    end
  end

  @doc """
  Returns true if the user has at least one auth method other than the
  one named in `exclude`. `exclude` is one of `:password`, `:api_key`,
  or `{:oauth_identity, identity_id}`.
  """
  def has_other_auth_method?(%User{} = user, opts) do
    exclude = Keyword.get(opts, :exclude)

    has_password? = exclude != :password and not is_nil(user.password_hash)
    has_api_key? = exclude != :api_key and not is_nil(user.api_key_hash)

    identity_count =
      case exclude do
        {:oauth_identity, id} ->
          Repo.aggregate(
            from(i in OauthIdentity, where: i.user_id == ^user.id and i.id != ^id),
            :count,
            :id
          )

        _ ->
          Repo.aggregate(from(i in OauthIdentity, where: i.user_id == ^user.id), :count, :id)
      end

    has_password? or has_api_key? or identity_count > 0
  end

  @doc """
  Links a new OAuth identity to a user. `attrs` must contain
  `provider_uid`, `email`, and may contain `raw_info`.
  """
  def link_identity(%User{} = user, provider, attrs) when is_binary(provider) and is_map(attrs) do
    full =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("provider", provider)
      |> Map.put("user_id", user.id)

    %OauthIdentity{} |> OauthIdentity.changeset(full) |> Repo.insert()
  end

  @doc """
  Returns the User linked to the given (provider, provider_uid), or nil.
  """
  def find_user_by_identity(provider, provider_uid)
      when is_binary(provider) and is_binary(provider_uid) do
    case Repo.get_by(OauthIdentity, provider: provider, provider_uid: provider_uid) do
      nil -> nil
      identity -> Repo.get(User, identity.user_id)
    end
  end

  @doc """
  Removes an identity. Refuses if doing so would leave the user with no
  auth method.
  """
  def unlink_identity(%User{} = user, identity_id) when is_integer(identity_id) do
    user = Repo.get!(User, user.id)

    if has_other_auth_method?(user, exclude: {:oauth_identity, identity_id}) do
      case Repo.get_by(OauthIdentity, id: identity_id, user_id: user.id) do
        nil ->
          {:error, Comn.Errors.Registry.error!("wagger.accounts/identity_not_found")}

        identity ->
          Repo.delete(identity)
      end
    else
      {:error, Comn.Errors.Registry.error!("wagger.accounts/orphan_account",
        message: "removing this would leave the account with no way to log in"
      )}
    end
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end
end
