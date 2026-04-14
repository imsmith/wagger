defmodule Wagger.DriftTest do
  @moduledoc """
  Tests for Wagger.Drift — drift detection between live routes and WAF config snapshots.

  Covers: never_generated, current, added, removed, modified, and checksum determinism.
  """

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes
  alias Wagger.Snapshots

  setup do
    {:ok, app} = Applications.create_application(%{"name" => "drift-test-app"})

    {:ok, users_route} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET", "POST"],
        "path_type" => "exact",
        "rate_limit" => 100
      })

    {:ok, health_route} =
      Routes.create_route(app, %{
        "path" => "/health",
        "methods" => ["GET"],
        "path_type" => "exact"
      })

    {:ok, app: app, users_route: users_route, health_route: health_route}
  end

  describe "detect/2 — never_generated" do
    test "returns :never_generated when no snapshot exists", %{app: app} do
      result = Drift.detect(app, "nginx")
      assert %Drift{status: :never_generated, provider: "nginx"} = result
    end
  end

  describe "detect/2 — current" do
    test "returns :current when routes match snapshot checksum", %{app: app} do
      routes = Routes.list_routes(app)
      normalized = Drift.normalize_for_snapshot(routes)
      checksum = Drift.compute_checksum(normalized)

      encoded =
        normalized
        |> :erlang.term_to_binary()
        |> Base.encode64()

      {:ok, _snapshot} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: encoded,
          output: "# generated",
          checksum: checksum
        })

      result = Drift.detect(app, "nginx")
      assert %Drift{status: :current, provider: "nginx"} = result
    end
  end

  describe "detect/2 — drifted: added routes" do
    test "detects routes added since snapshot", %{app: app} do
      # Snapshot contains only /health
      snapshot_routes = [
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      encoded =
        snapshot_routes
        |> :erlang.term_to_binary()
        |> Base.encode64()

      checksum = Drift.compute_checksum(snapshot_routes)

      {:ok, _} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: encoded,
          output: "# generated",
          checksum: checksum
        })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert "/api/users" in result.changes.added
      assert result.changes.removed == []
    end
  end

  describe "detect/2 — drifted: removed routes" do
    test "detects routes removed since snapshot", %{app: app} do
      # Snapshot contains an extra route that no longer exists
      snapshot_routes = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/api/legacy", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      encoded =
        snapshot_routes
        |> :erlang.term_to_binary()
        |> Base.encode64()

      checksum = Drift.compute_checksum(snapshot_routes)

      {:ok, _} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: encoded,
          output: "# generated",
          checksum: checksum
        })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert "/api/legacy" in result.changes.removed
      assert result.changes.added == []
    end
  end

  describe "detect/2 — drifted: modified routes" do
    test "detects routes with changed methods or rate_limit", %{app: app} do
      # Snapshot has /api/users with different rate_limit and methods
      snapshot_routes = [
        %{path: "/api/users", methods: ["GET"], path_type: "exact", rate_limit: 50},
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      encoded =
        snapshot_routes
        |> :erlang.term_to_binary()
        |> Base.encode64()

      checksum = Drift.compute_checksum(snapshot_routes)

      {:ok, _} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: encoded,
          output: "# generated",
          checksum: checksum
        })

      result = Drift.detect(app, "nginx")
      assert result.status == :drifted
      assert "/api/users" in result.changes.modified
      assert result.changes.added == []
      assert result.changes.removed == []
    end
  end

  describe "compute_checksum/1" do
    test "is deterministic — same input produces same output" do
      routes = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
        %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      assert Drift.compute_checksum(routes) == Drift.compute_checksum(routes)
    end

    test "differs for different inputs" do
      routes_a = [%{path: "/api/users", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      routes_b = [%{path: "/api/users", methods: ["POST"], path_type: "exact", rate_limit: nil}]

      refute Drift.compute_checksum(routes_a) == Drift.compute_checksum(routes_b)
    end
  end
end
