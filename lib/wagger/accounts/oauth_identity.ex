defmodule Wagger.Accounts.OauthIdentity do
  @moduledoc """
  Ecto schema for an OAuth identity linked to a User. A User may have
  multiple identities across providers; identities are keyed uniquely
  by (provider, provider_uid).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  @valid_providers ~w(google github)

  schema "oauth_identities" do
    field :provider, :string
    field :provider_uid, :string
    field :email, :string
    field :raw_info, :string

    belongs_to :user, Wagger.Accounts.User

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc "Changeset for creating or updating an OAuth identity."
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_uid, :email, :raw_info, :user_id])
    |> validate_required([:provider, :provider_uid, :email, :user_id])
    |> validate_inclusion(:provider, @valid_providers)
    |> unique_constraint(:provider_uid,
      name: :oauth_identities_provider_provider_uid_index
    )
    |> assoc_constraint(:user)
  end
end
