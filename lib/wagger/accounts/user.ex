defmodule Wagger.Accounts.User do
  @moduledoc """
  Ecto schema for a User — a human operator with API key authentication.

  Users authenticate via API keys. The key itself is never stored; only a
  SHA-256 hex digest of the key is persisted. Usernames must be lowercase slugs
  and are unique across the system.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :password_hash, :string
    field :api_key_hash, :string

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc """
  Changeset for creating or updating a User.

  Casts username, display_name, password_hash, and api_key_hash. Requires username.
  Validates username format as a lowercase slug and enforces uniqueness on both
  username and api_key_hash.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :display_name, :password_hash, :api_key_hash])
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9\-]*$/, message: "must be a lowercase slug (letters, digits, hyphens)")
    |> unique_constraint(:username)
    |> unique_constraint(:api_key_hash)
  end
end
