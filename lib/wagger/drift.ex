defmodule Wagger.Drift do
  @moduledoc """
  Drift detection between current application routes and the last generated WAF config snapshot.

  Computes a structural diff by comparing normalized route maps from the live database
  against the decoded route snapshot stored by `Wagger.Snapshots`. Uses a SHA-256
  checksum as a fast-path to skip decoding when nothing has changed.
  """

  alias Wagger.Routes
  alias Wagger.Snapshots
  alias Wagger.Applications.Application

  @enforce_keys []
  defstruct [:status, :provider, :last_generated, changes: %{added: [], removed: [], modified: []}]

  @doc """
  Detects drift between the current routes for `app` and the last snapshot for `provider`.

  Returns a `%Drift{}` struct with one of:
  - `status: :never_generated` — no snapshot exists yet
  - `status: :current` — checksum matches, no diff computed
  - `status: :drifted` — checksum differs; `changes` contains added/removed/modified paths
  """
  def detect(%Application{} = app, provider) when is_binary(provider) do
    current_routes = Routes.list_routes(app)
    normalized = normalize_for_snapshot(current_routes)
    current_checksum = compute_checksum(normalized)

    case Snapshots.latest_snapshot(app, provider) do
      nil ->
        %__MODULE__{status: :never_generated, provider: provider}

      snapshot when snapshot.checksum == current_checksum ->
        %__MODULE__{
          status: :current,
          provider: provider,
          last_generated: snapshot.inserted_at
        }

      snapshot ->
        snapshot_routes = decode_snapshot(snapshot.route_snapshot)
        changes = structural_diff(normalized, snapshot_routes)

        %__MODULE__{
          status: :drifted,
          provider: provider,
          last_generated: snapshot.inserted_at,
          changes: changes
        }
    end
  end

  @doc """
  Normalizes a list of route structs to plain maps containing only the fields
  relevant to WAF config generation: `path`, `methods`, `path_type`, `rate_limit`.

  Call this before computing a checksum or encoding a route snapshot.
  """
  def normalize_for_snapshot(routes) do
    Enum.map(routes, fn route ->
      %{
        path: route.path,
        methods: route.methods,
        path_type: route.path_type,
        rate_limit: route.rate_limit
      }
    end)
  end

  @doc """
  Computes a deterministic SHA-256 checksum over a list of normalized route maps.

  Routes are sorted by path before hashing to ensure order-independence.
  Returns a lowercase hex string.
  """
  def compute_checksum(normalized_routes) do
    normalized_routes
    |> Enum.sort_by(& &1.path)
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Decodes a stored route_snapshot field back to a list of normalized route maps.
  defp decode_snapshot(encoded) do
    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  # Computes added/removed/modified between current normalized routes and snapshot routes.
  defp structural_diff(current_routes, snapshot_routes) do
    current_by_path = Map.new(current_routes, &{&1.path, &1})
    snapshot_by_path = Map.new(snapshot_routes, &{&1.path, &1})

    current_paths = MapSet.new(Map.keys(current_by_path))
    snapshot_paths = MapSet.new(Map.keys(snapshot_by_path))

    added =
      current_paths
      |> MapSet.difference(snapshot_paths)
      |> MapSet.to_list()
      |> Enum.sort()

    removed =
      snapshot_paths
      |> MapSet.difference(current_paths)
      |> MapSet.to_list()
      |> Enum.sort()

    modified =
      current_paths
      |> MapSet.intersection(snapshot_paths)
      |> MapSet.to_list()
      |> Enum.filter(fn path ->
        current = Map.fetch!(current_by_path, path)
        snapped = Map.fetch!(snapshot_by_path, path)
        routes_differ?(current, snapped)
      end)
      |> Enum.sort()

    %{added: added, removed: removed, modified: modified}
  end

  defp routes_differ?(a, b) do
    Enum.sort(a.methods) != Enum.sort(b.methods) or
      a.path_type != b.path_type or
      a.rate_limit != b.rate_limit
  end
end
