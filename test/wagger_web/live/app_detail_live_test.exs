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

    test "displays routes with method pills", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "GET"
      assert html =~ "POST"
      assert html =~ "DELETE"
    end

    test "groups routes by common prefix", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "/api/users"
    end

    test "shows rate limit when present", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "100/min"
    end

    test "highlights path parameters", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "{id}"
    end
  end
end
