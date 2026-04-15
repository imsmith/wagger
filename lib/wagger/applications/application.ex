defmodule Wagger.Applications.Application do
  @moduledoc """
  Ecto schema for an Application — a named API surface with optional description and tags.

  Applications are the top-level grouping for routes in Wagger. The name must be a
  lowercase slug (`[a-z0-9][a-z0-9-]*`) and is unique across the system. Tags are stored
  as an EDN list and support tag-based filtering.

  ## Visibility and Sharing

  - `public` — when true, the application is visible to unauthenticated users
  - `shareable` — when true, the application appears in the public Hub for anyone to
    browse routes and generate configs. Requires `public: true`.

  ## Route Tracking

  - `source` — optional file path or URL where routes were imported from
  - `route_checksum` — SHA-256 of the current normalized route set, automatically
    updated on every route create/update/delete via `Wagger.Routes`
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {Wagger.Applications.Application, :timestamp_now, []}
  ]

  schema "applications" do
    field :name, :string
    field :description, :string
    field :tags, Wagger.Ecto.EdnList
    field :source, :string
    field :route_checksum, :string
    field :public, :boolean, default: false
    field :shareable, :boolean, default: false

    has_many :routes, Wagger.Applications.Route

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc """
  Changeset for creating or updating an Application.

  Casts name, description, and tags. Requires name. Validates name format as a
  lowercase slug and enforces uniqueness.
  """
  def changeset(application, attrs) do
    application
    |> cast(attrs, [:name, :description, :tags, :source, :route_checksum, :public, :shareable])
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9\-]*$/,
      message: "must be a lowercase slug (letters, digits, hyphens)"
    )
    |> unique_constraint(:name)
  end
end
