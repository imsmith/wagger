defmodule Wagger.Snapshots do
  @moduledoc """
  Context module for managing Snapshots.

  Snapshots are immutable records of WAF config generation events, scoped to an
  Application and keyed by provider. Use this context to record generation history
  and retrieve the most recent snapshot for drift detection.
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Applications.Application
  alias Wagger.Snapshots.Snapshot

  @doc """
  Creates a Snapshot with the given attributes.

  Returns `{:ok, %Snapshot{}}` on success or `{:error, %Ecto.Changeset{}}` on failure.
  """
  def create_snapshot(attrs \\ %{}) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all Snapshots for the given Application, optionally filtered by provider.

  Accepts an optional `filters` map. If the map contains the key `"provider"`, only
  snapshots matching that provider are returned. Results are ordered by id descending
  (most recent first).

  ## Examples

      iex> list_snapshots(app)
      [%Snapshot{}, ...]

      iex> list_snapshots(app, %{"provider" => "nginx"})
      [%Snapshot{provider: "nginx"}, ...]

  """
  def list_snapshots(%Application{} = app, filters \\ %{}) do
    Snapshot
    |> where([s], s.application_id == ^app.id)
    |> apply_provider_filter(filters)
    |> order_by([s], desc: s.id)
    |> Repo.all()
  end

  defp apply_provider_filter(query, %{"provider" => provider}) when is_binary(provider) do
    where(query, [s], s.provider == ^provider)
  end

  defp apply_provider_filter(query, _filters), do: query

  @doc """
  Gets a single Snapshot by ID, scoped to the given Application.

  Raises `Ecto.NoResultsError` if the snapshot is not found or does not belong to the app.
  """
  def get_snapshot!(%Application{} = app, id) do
    Snapshot
    |> where([s], s.application_id == ^app.id and s.id == ^id)
    |> Repo.one!()
  end

  @doc """
  Returns the most recent Snapshot for the given Application and provider.

  Returns `nil` if no snapshot exists for the app+provider combination.
  """
  def latest_snapshot(%Application{} = app, provider) when is_binary(provider) do
    Snapshot
    |> where([s], s.application_id == ^app.id and s.provider == ^provider)
    |> order_by([s], desc: s.id)
    |> limit(1)
    |> Repo.one()
  end
end
