defmodule WaggerWeb.DriftControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes
  alias Wagger.Snapshots

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "driftuser"})
    {:ok, app} = Applications.create_application(%{"name" => "drift-app", "tags" => ["api"]})

    {:ok, _route} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET"],
        "path_type" => "exact"
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "show — never_generated" do
    test "returns never_generated when no snapshots exist", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")
      assert %{"provider" => "nginx", "status" => "never_generated"} = json_response(conn, 200)
    end
  end

  describe "show — current" do
    test "returns current when snapshot checksum matches current routes", %{conn: conn, app: app} do
      routes = Routes.list_routes(app)
      route_data = Drift.normalize_for_snapshot(routes)
      checksum = Drift.compute_checksum(route_data)

      {:ok, _snapshot} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
          output: "server {}",
          checksum: checksum
        })

      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")
      assert %{"provider" => "nginx", "status" => "current", "last_generated" => ts} =
               json_response(conn, 200)

      assert is_binary(ts)
    end
  end

  describe "show — drifted" do
    test "returns drifted with added routes when snapshot was created with empty routes", %{
      conn: conn,
      app: app
    } do
      # Snapshot with empty route set — current has one route, so it'll show as added
      empty_route_data = []
      empty_checksum = Drift.compute_checksum(empty_route_data)

      {:ok, _snapshot} =
        Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: "nginx",
          route_snapshot: :erlang.term_to_binary(empty_route_data) |> Base.encode64(),
          output: "server {}",
          checksum: empty_checksum
        })

      conn = get(conn, ~p"/api/applications/#{app.id}/drift/nginx")

      assert %{
               "provider" => "nginx",
               "status" => "drifted",
               "last_generated" => ts,
               "changes" => changes
             } = json_response(conn, 200)

      assert is_binary(ts)
      assert length(changes["added"]) == 1
      assert hd(changes["added"])["path"] == "/api/users"
      assert changes["removed"] == []
    end
  end
end
