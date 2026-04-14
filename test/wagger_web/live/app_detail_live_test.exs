defmodule WaggerWeb.AppDetailLiveTest do
  @moduledoc false

  use WaggerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wagger.Applications
  alias Wagger.Routes

  setup do
    {:ok, app} =
      Applications.create_application(%{
        "name" => "test-app",
        "description" => "Test application"
      })

    {:ok, _route1} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET", "POST"],
        "path_type" => "exact",
        "rate_limit" => 100
      })

    {:ok, _route2} =
      Routes.create_route(app, %{
        "path" => "/api/users/{id}",
        "methods" => ["GET", "PUT", "DELETE"],
        "path_type" => "exact"
      })

    {:ok, _route3} =
      Routes.create_route(app, %{
        "path" => "/health",
        "methods" => ["GET"],
        "path_type" => "exact"
      })

    %{app: app}
  end

  describe "AppDetailLive" do
    test "renders app name and route count", %{conn: conn, app: app} do
      {:ok, lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "test-app"
      assert html =~ "3"
      assert has_element?(lv, "h1", "test-app")
    end

    test "shows treemap cells for route groups", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      # Top level should show "api" and "health" segments
      assert html =~ "api"
      assert html =~ "health"
      assert html =~ "endpoint"
    end

    test "drills into treemap on click", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # Click "api" to drill in
      html = lv |> element(~s(button[phx-value-segment="api"])) |> render_click()

      # Should now show "users" as a child
      assert html =~ "users"
    end

    test "shows endpoint rows at leaf level", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # Drill to api -> users -> {id} (leaf node)
      lv |> element(~s(button[phx-value-segment="api"])) |> render_click()
      lv |> element(~s(button[phx-value-segment="users"])) |> render_click()
      html = lv |> element(~s(button[phx-value-segment="{id}"])) |> render_click()

      # Leaf level shows SwaggerUI rows with method pills
      assert html =~ "GET"
      assert html =~ "PUT"
      assert html =~ "DELETE"
    end

    test "shows own routes at intermediate level", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # Drill to api -> users (has both own routes and child {id})
      lv |> element(~s(button[phx-value-segment="api"])) |> render_click()
      html = lv |> element(~s(button[phx-value-segment="users"])) |> render_click()

      # Should show own endpoints (GET, POST on /api/users) and {id} as a treemap cell
      assert html =~ "GET"
      assert html =~ "POST"
      assert html =~ "100/min"
      assert html =~ "{id}"
    end

    test "search finds routes across tree", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      html = lv |> form("form", %{query: "health"}) |> render_change()

      assert html =~ "/health"
      assert html =~ "GET"
    end

    test "breadcrumb navigation works", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # Drill into api
      lv |> element(~s(button[phx-value-segment="api"])) |> render_click()

      # Click breadcrumb to go back to root
      html = lv |> element(~s(button[phx-value-depth="0"])) |> render_click()

      # Should be back at top level
      assert html =~ "api"
      assert html =~ "health"
    end
  end
end
