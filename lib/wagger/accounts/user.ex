defmodule Wagger.Accounts.User do
  @moduledoc """
  Ecto schema for a User — a human operator.

  Authentication paths: API key (existing), OAuth via linked
  `oauth_identities` (browser), and local password (browser).
  Usernames must be lowercase slugs and are unique. Email is
  optional but unique when present.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  @valid_roles ~w(admin user)

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :email, :string
    field :role, :string, default: "user"
    field :password_hash, :string
    field :api_key_hash, :string

    belongs_to :invite_code, Wagger.Invites.InviteCode

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc """
  Canonical form of an email address: trimmed and downcased. Applied on
  write and on lookup so that an address entered with stray capitals or
  padding still matches the stored row.
  """
  def normalize_email(nil), do: nil
  def normalize_email(email) when is_binary(email), do: email |> String.trim() |> String.downcase()

  @doc """
  Changeset for creating or updating a User.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :display_name,
      :email,
      :role,
      :password_hash,
      :api_key_hash,
      :invite_code_id
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9\-]*$/,
      message: "must be a lowercase slug (letters, digits, hyphens)"
    )
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:api_key_hash)
    |> assoc_constraint(:invite_code)
  end
end
