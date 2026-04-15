defmodule Wagger.Snapshots do
  @moduledoc """
  Context module for managing Snapshots.

  Snapshots are immutable records of WAF config generation events, scoped to an
  Application and keyed by provider. Use this context to record generation history
  and retrieve the most recent snapshot for drift detection.

  The `output` field is encrypted at rest via `Wagger.Secrets`. Use
  `decrypt_output/1` to retrieve plaintext. Pre-encryption snapshots are
  handled gracefully via fallback.
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
    attrs = encrypt_output(attrs)

    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  defp encrypt_output(attrs) do
    {key, output} =
      cond do
        Map.has_key?(attrs, :output) -> {:output, Map.get(attrs, :output)}
        Map.has_key?(attrs, "output") -> {"output", Map.get(attrs, "output")}
        true -> {nil, nil}
      end

    case {key, output} do
      {nil, _} -> attrs
      {_, nil} -> attrs
      {k, plaintext} ->
        case Wagger.Secrets.lock(plaintext) do
          {:ok, locked} -> Map.put(attrs, k, locked)
          {:error, _} -> attrs
        end
    end
  end

  @doc """
  Deletes all snapshots for the given application and provider.

  Returns `{count, nil}` where count is the number of deleted rows.
  """
  def delete_snapshots_for_provider(%Application{} = app, provider) when is_binary(provider) do
    Snapshot
    |> where([s], s.application_id == ^app.id and s.provider == ^provider)
    |> Repo.delete_all()
  end

  @doc """
  Decrypts and returns the output from a snapshot.

  Falls back to the raw output if decryption fails (handles
  snapshots created before encryption was enabled).
  """
  def decrypt_output(%Snapshot{output: output}) when is_binary(output) do
    case Wagger.Secrets.unlock(output) do
      {:ok, plaintext} -> plaintext
      {:error, _} -> output
    end
  rescue
    ArgumentError -> output
  end

  def decrypt_output(_), do: nil

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
