defmodule WaggerWeb.DashboardLiveTest do
  @moduledoc false

  use WaggerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes
  alias Wagger.Snapshots

  defp create_app_with_route(_context) do
    {:ok, app} =
      Applications.create_application(%{
        "name" => "test-app",
        "description" => "A test application"
      })

    {:ok, _route} =
      Routes.create_route(app, %{
        "path" => "/api/health",
        "methods" => ["GET"],
        "path_type" => "exact"
      })

    %{app: app}
  end

  describe "renders status summary cards" do
    setup :create_app_with_route

    test "mounts and shows status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Drifted"
      assert html =~ "Current"
      assert html =~ "Never Generated"
    end

    test "shows the hint text when no filter selected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Click a status above to see affected applications"
    end
  end

  describe "shows app cards when status is clicked" do
    setup :create_app_with_route

    test "clicking current status card shows apps with current snapshots", %{conn: conn, app: app} do
      # Create a snapshot so this app is "current" for nginx
      routes = Routes.list_routes(app)
      route_data = Drift.normalize_for_snapshot(routes)
      checksum = Drift.compute_checksum(route_data)

      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("[phx-value-status=current]") |> render_click()

      assert html =~ app.name
    end
  end

  describe "navigates to app detail" do
    setup :create_app_with_route

    test "app card has data-app-id after filtering", %{conn: conn, app: app} do
      # Create a snapshot so the app appears under "current"
      routes = Routes.list_routes(app)
      route_data = Drift.normalize_for_snapshot(routes)
      checksum = Drift.compute_checksum(route_data)

      Snapshots.create_snapshot(%{
        application_id: app.id,
        provider: "nginx",
        route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
        output: "server {}",
        checksum: checksum
      })

      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("[phx-value-status=current]") |> render_click()

      assert html =~ "data-app-id=\"#{app.id}\""
    end
  end
end
