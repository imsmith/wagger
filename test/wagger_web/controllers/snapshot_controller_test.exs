defmodule WaggerWeb.SnapshotControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes
  alias Wagger.Snapshots

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "snapuser"})
    {:ok, app} = Applications.create_application(%{"name" => "snap-app", "tags" => ["api"]})

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  defp make_snapshot(app, provider, output \\ "server {}") do
    routes = Routes.list_routes(app)
    route_data = Drift.normalize_for_snapshot(routes)
    checksum = Drift.compute_checksum(route_data)

    {:ok, snapshot} =
      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: provider,
        route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
        output: output,
        checksum: checksum
      })

    snapshot
  end

  describe "index" do
    test "lists all snapshots for the application", %{conn: conn, app: app} do
      s1 = make_snapshot(app, "nginx", "nginx output")
      s2 = make_snapshot(app, "aws", "aws output")

      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots")
      assert %{"data" => data} = json_response(conn, 200)
      ids = Enum.map(data, & &1["id"])
      assert s1.id in ids
      assert s2.id in ids
    end

    test "filters snapshots by provider", %{conn: conn, app: app} do
      make_snapshot(app, "nginx")
      make_snapshot(app, "aws")

      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots?provider=nginx")
      assert %{"data" => data} = json_response(conn, 200)
      assert length(data) == 1
      assert hd(data)["provider"] == "nginx"
    end

    test "summary fields do not include output", %{conn: conn, app: app} do
      make_snapshot(app, "nginx")

      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots")
      assert %{"data" => [item]} = json_response(conn, 200)
      assert Map.has_key?(item, "id")
      assert Map.has_key?(item, "provider")
      assert Map.has_key?(item, "checksum")
      assert Map.has_key?(item, "inserted_at")
      refute Map.has_key?(item, "output")
    end
  end

  describe "show" do
    test "returns snapshot with full output", %{conn: conn, app: app} do
      snapshot = make_snapshot(app, "nginx", "# nginx config")

      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots/#{snapshot.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == snapshot.id
      assert data["provider"] == "nginx"
      assert data["output"] == "# nginx config"
      assert Map.has_key?(data, "config_params")
      assert Map.has_key?(data, "checksum")
    end

    test "returns 404 for unknown snapshot id", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/snapshots/0")
      assert json_response(conn, 404)
    end
  end
end
