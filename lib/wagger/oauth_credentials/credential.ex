defmodule Wagger.OauthCredentials.Credential do
  @moduledoc """
  Ecto schema for an OAuth provider's credentials (client_id + locked
  client_secret). Secret is encrypted at rest via Wagger.Secrets.lock/1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  schema "oauth_provider_credentials" do
    field :provider, :string
    field :client_id, :string
    field :client_secret_locked, :string

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [:provider, :client_id, :client_secret_locked])
    |> validate_required([:provider, :client_id, :client_secret_locked])
    |> validate_inclusion(:provider, ~w(google github))
    |> unique_constraint(:provider)
  end
end
