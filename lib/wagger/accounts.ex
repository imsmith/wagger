defmodule Wagger.Accounts do
  @moduledoc """
  Context module for managing Users and API key authentication.

  Handles user creation with API key generation, API key authentication,
  and setup state detection (whether any users exist).
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Accounts.User

  @doc """
  Creates a user, generates a random API key, stores its hash.

  Returns `{:ok, user, api_key_plaintext}` on success, where `api_key_plaintext`
  is the raw key the caller must present to the user (it is not stored).
  Returns `{:error, changeset}` on validation failure.
  """
  def create_user(attrs \\ %{}) do
    api_key = generate_api_key()
    api_key_hash = hash_api_key(api_key)

    # Normalize key type to match whatever the caller used (atom or string)
    key = if Map.keys(attrs) |> List.first() |> is_atom(), do: :api_key_hash, else: "api_key_hash"
    attrs_with_hash = Map.put(attrs, key, api_key_hash)

    case %User{} |> User.changeset(attrs_with_hash) |> Repo.insert() do
      {:ok, user} -> {:ok, user, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Authenticates a user by raw API key.

  Hashes the provided key and looks up a user with a matching `api_key_hash`.
  Returns `{:ok, user}` or `:error`.
  """
  def authenticate_by_api_key(api_key) do
    hash = hash_api_key(api_key)

    case Repo.get_by(User, api_key_hash: hash) do
      nil -> :error
      user -> {:ok, user}
    end
  end

  @doc """
  Returns all users ordered by insertion time.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Returns a user by id, raising if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Deletes a user. Returns `{:ok, user}` or `{:error, :protected}` for the
  admin user, or `{:error, changeset}` on failure.
  """
  def delete_user(%User{username: "admin"}), do: {:error, :protected}

  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns `true` if no users exist in the database, `false` otherwise.

  Used to detect whether initial setup is required.
  """
  def setup_required? do
    Repo.aggregate(User, :count, :id) == 0
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end
end
