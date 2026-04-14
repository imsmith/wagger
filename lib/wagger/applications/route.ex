defmodule Wagger.Applications.Route do
  @moduledoc """
  Ecto schema for a Route belonging to an Application.

  This module is a placeholder stub created to satisfy Ecto's association
  resolution for `Wagger.Applications.Application.has_many :routes`. Task 5
  will expand this into the full Route schema with changeset and context.
  """

  use Ecto.Schema

  @timestamps_opts [
    type: :string,
    autogenerate: {Wagger.Applications.Application, :timestamp_now, []}
  ]

  schema "routes" do
    field :path, :string
    field :methods, Wagger.Ecto.EdnList
    field :path_type, :string
    field :description, :string
    field :query_params, Wagger.Ecto.EdnMapList
    field :headers, Wagger.Ecto.EdnMapList
    field :rate_limit, :integer
    field :tags, Wagger.Ecto.EdnList

    belongs_to :application, Wagger.Applications.Application

    timestamps(type: :string)
  end
end
