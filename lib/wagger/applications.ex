defmodule Wagger.Applications do
  @moduledoc """
  Context module for managing Applications.

  Provides CRUD operations and tag-based filtering over the `applications` table.
  Tags are stored as EDN lists (e.g. `"[:api :public]"`) and can be queried by
  keyword membership using substring matching.
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Applications.Application

  @doc """
  Returns all applications, optionally filtered by tag.

  Accepts an optional `filters` map. If the map contains the key `"tag"`, only
  applications whose tags EDN string contains that keyword are returned.

  ## Examples

      iex> list_applications()
      [%Application{}, ...]

      iex> list_applications(%{"tag" => "public"})
      [%Application{tags: ["api", "public"]}, ...]

  """
  def list_applications(filters \\ %{}) do
    Application
    |> apply_tag_filter(filters)
    |> Repo.all()
  end

  defp apply_tag_filter(query, %{"tag" => tag}) when is_binary(tag) do
    where(query, [a], like(a.tags, ^"%:#{tag}%"))
  end

  defp apply_tag_filter(query, _filters), do: query

  @doc """
  Gets a single Application by ID. Raises `Ecto.NoResultsError` if not found.
  """
  def get_application!(id), do: Repo.get!(Application, id)

  @doc """
  Creates an Application with the given attributes.

  Returns `{:ok, %Application{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def create_application(attrs \\ %{}) do
    %Application{}
    |> Application.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an existing Application with the given attributes.

  Returns `{:ok, %Application{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def update_application(%Application{} = application, attrs) do
    application
    |> Application.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an Application.

  Returns `{:ok, %Application{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def delete_application(%Application{} = application) do
    Repo.delete(application)
  end
end
