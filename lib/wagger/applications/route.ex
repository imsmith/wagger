defmodule Wagger.Applications.Route do
  @moduledoc """
  Ecto schema for a Route belonging to an Application.

  Routes describe individual API endpoints within an application. Each route has
  a path, one or more HTTP methods, a path_type (exact, prefix, or regex), and
  optional metadata including description, query_params, headers, rate_limit,
  and tags.

  Tags and methods are stored as EDN lists. Query params and headers are stored
  as EDN map lists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {Wagger.Applications.Application, :timestamp_now, []}
  ]

  @valid_path_types ~w(exact prefix regex)

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

  @doc """
  Changeset for creating or updating a Route.

  Casts all fields, requires path and path_type, validates path_type is one of
  "exact", "prefix", or "regex", defaults methods to ["GET"] when absent or
  empty, and enforces uniqueness of path within an application.
  """
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :path,
      :methods,
      :path_type,
      :description,
      :query_params,
      :headers,
      :rate_limit,
      :tags
    ])
    |> validate_required([:path, :path_type])
    |> validate_inclusion(:path_type, @valid_path_types)
    |> validate_regex_path()
    |> put_default_methods()
    |> unique_constraint([:application_id, :path])
  end

  defp put_default_methods(changeset) do
    case get_field(changeset, :methods) do
      nil -> put_change(changeset, :methods, ["GET"])
      [] -> put_change(changeset, :methods, ["GET"])
      _ -> changeset
    end
  end

  defp validate_regex_path(changeset) do
    case {get_field(changeset, :path_type), get_field(changeset, :path)} do
      {"regex", path} when is_binary(path) ->
        case Regex.compile(path) do
          {:ok, _} -> changeset
          {:error, {reason, _pos}} -> add_error(changeset, :path, "invalid regex: #{reason}")
        end

      _ ->
        changeset
    end
  end
end
