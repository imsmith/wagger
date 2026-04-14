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
    %Route{application_id: app.id}
    |> Route.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing Route with the given attributes.

  Returns `{:ok, %Route{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def update_route(%Route{} = route, attrs) do
    route
    |> Route.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Route.

  Returns `{:ok, %Route{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def delete_route(%Route{} = route) do
    Repo.delete(route)
  end
end
