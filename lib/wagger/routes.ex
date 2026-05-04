defmodule Wagger.Routes do
  @moduledoc """
  Context module for managing Routes within an Application.

  All functions are scoped to a given `%Application{}` struct to enforce
  data isolation between applications. Routes store HTTP methods and tags as
  EDN lists, enabling keyword-based substring filtering.
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Applications.Application
  alias Wagger.Applications.Route
  alias Wagger.Generator.PathHelper

  @type lookup_match :: %{
          route_id: integer(),
          path: String.t(),
          path_type: String.t(),
          methods: [String.t()],
          method_allowed: boolean(),
          rate_limit: integer() | nil,
          description: String.t() | nil
        }

  @type lookup_result :: %{
          verdict: :allowed | :method_not_allowed | :not_in_allowlist,
          method: String.t(),
          path: String.t(),
          matches: [lookup_match()]
        }

  @doc """
  Returns all routes for the given application, optionally filtered.

  Supported filters:
  - `"tag"` — routes whose tags EDN string contains the given keyword
  - `"method"` — routes whose methods EDN string contains the given keyword
  - `"path_type"` — exact match on path_type field

  ## Examples

      iex> list_routes(app)
      [%Route{}, ...]

      iex> list_routes(app, %{"tag" => "public"})
      [%Route{tags: ["public"]}, ...]

  """
  def list_routes(%Application{} = app, filters \\ %{}) do
    Route
    |> where([r], r.application_id == ^app.id)
    |> apply_tag_filter(filters)
    |> apply_method_filter(filters)
    |> apply_path_type_filter(filters)
    |> Repo.all()
  end

  defp apply_tag_filter(query, %{"tag" => tag}) when is_binary(tag) do
    where(query, [r], like(r.tags, ^"%:#{tag}%"))
  end

  defp apply_tag_filter(query, _), do: query

  defp apply_method_filter(query, %{"method" => method}) when is_binary(method) do
    where(query, [r], like(r.methods, ^"%:#{method}%"))
  end

  defp apply_method_filter(query, _), do: query

  defp apply_path_type_filter(query, %{"path_type" => path_type}) when is_binary(path_type) do
    where(query, [r], r.path_type == ^path_type)
  end

  defp apply_path_type_filter(query, _), do: query

  @doc """
  Gets a single Route by ID, scoped to the given application.

  Raises `Ecto.NoResultsError` if not found or if the route does not belong to
  the given application.
  """
  def get_route!(%Application{} = app, id) do
    Route
    |> where([r], r.application_id == ^app.id and r.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Creates a Route for the given application with the given attributes.

  Returns `{:ok, %Route{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def create_route(%Application{} = app, attrs \\ %{}) do
    result =
      %Route{application_id: app.id}
      |> Route.changeset(attrs)
      |> Repo.insert()

    with {:ok, route} <- result do
      update_route_checksum(app)
      Wagger.Events.route_changed(:created, route)
      {:ok, route}
    end
  end

  @doc """
  Updates an existing Route with the given attributes.

  Returns `{:ok, %Route{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def update_route(%Route{} = route, attrs) do
    result =
      route
      |> Route.changeset(attrs)
      |> Repo.update()

    with {:ok, updated} <- result do
      app = Wagger.Applications.get_application!(updated.application_id)
      update_route_checksum(app)
      Wagger.Events.route_changed(:updated, updated)
      {:ok, updated}
    end
  end

  @doc """
  Deletes a Route.

  Returns `{:ok, %Route{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def delete_route(%Route{} = route) do
    result = Repo.delete(route)

    with {:ok, deleted} <- result do
      app = Wagger.Applications.get_application!(deleted.application_id)
      update_route_checksum(app)
      Wagger.Events.route_changed(:deleted, deleted)
      {:ok, deleted}
    end
  end

  @doc """
  Looks up which declared route(s) match a given HTTP method and request path.

  Normalises the input method to uppercase, then tests each route's compiled
  regex (via `PathHelper.to_regex/1`) against the path. Returns a structured
  map with:

  - `verdict` — `:allowed` if any match allows the method, `:method_not_allowed`
    if matches exist but none allow the method, `:not_in_allowlist` if no route
    path matches at all.
  - `method` — the normalised (uppercased) input method.
  - `path` — the input path, unchanged.
  - `matches` — list of matching routes, sorted most-specific first (exact <
    prefix < regex, then by declared path length descending within each type).

  ## Examples

      iex> lookup_for_request(app, "get", "/api/users/123")
      %{
        verdict: :allowed,
        method: "GET",
        path: "/api/users/123",
        matches: [%{route_id: 1, path: "/api/users/{id}", ...}]
      }

  """
  @spec lookup_for_request(Application.t(), String.t(), String.t()) :: lookup_result()
  def lookup_for_request(%Application{} = app, method, path)
      when is_binary(method) and is_binary(path) do
    method_upper = String.upcase(method)
    routes = list_routes(app)

    matches =
      routes
      |> Enum.filter(&path_matches?(&1, path))
      |> Enum.map(&build_match(&1, method_upper))
      |> sort_by_specificity()

    verdict =
      cond do
        matches == [] -> :not_in_allowlist
        Enum.any?(matches, & &1.method_allowed) -> :allowed
        true -> :method_not_allowed
      end

    %{verdict: verdict, method: method_upper, path: path, matches: matches}
  end

  # -- private helpers for lookup --

  @specificity_order %{"exact" => 0, "prefix" => 1, "regex" => 2}

  defp path_matches?(route, path) do
    regex_str = PathHelper.to_regex(route)

    case Regex.compile(regex_str) do
      {:ok, regex} -> Regex.match?(regex, path)
      {:error, _} -> false
    end
  end

  defp build_match(route, method_upper) do
    %{
      route_id: route.id,
      path: route.path,
      path_type: route.path_type,
      methods: route.methods,
      method_allowed: method_upper in route.methods,
      rate_limit: route.rate_limit,
      description: route.description
    }
  end

  defp sort_by_specificity(matches) do
    Enum.sort_by(matches, fn m ->
      type_order = Map.get(@specificity_order, m.path_type, 3)
      path_len = -String.length(m.path)
      {type_order, path_len}
    end)
  end

  defp update_route_checksum(%Application{} = app) do
    routes = list_routes(app)
    normalized = Wagger.Drift.normalize_for_snapshot(routes)
    checksum = Wagger.Drift.compute_checksum(normalized)
    Wagger.Applications.update_application(app, %{route_checksum: checksum})
  end
end
