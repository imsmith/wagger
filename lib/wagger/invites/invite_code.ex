defmodule Wagger.Invites.InviteCode do
  @moduledoc """
  Ecto schema for an invite code. Codes are short, URL-safe slugs that
  gate registration of new users via OAuth. They may be labeled, expire,
  or be capped at a maximum number of uses, and can be soft-revoked.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  schema "invite_codes" do
    field :code, :string
    field :label, :string
    field :expires_at, :string
    field :max_uses, :integer
    field :uses_count, :integer, default: 0
    field :revoked_at, :string

    belongs_to :created_by, Wagger.Accounts.User, foreign_key: :created_by_user_id

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc "Changeset for creating an invite code."
  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code, :label, :expires_at, :max_uses, :uses_count, :revoked_at, :created_by_user_id])
    |> validate_required([:code])
    |> unique_constraint(:code)
  end
end
