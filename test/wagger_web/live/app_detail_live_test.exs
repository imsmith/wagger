defmodule WaggerWeb.AppDetailLiveTest do
  @moduledoc false

  use WaggerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wagger.Applications
  alias Wagger.Generator.Multi
  alias Wagger.Routes
  alias Wagger.Snapshots

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

      html = lv |> form("form[phx-change=search_routes]", %{query: "health"}) |> render_change()

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

  describe "GCP coupled provider" do
    test "provider list does not include gcp_urlmap", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")
      refute html =~ "gcp_urlmap"
      refute html =~ "Gcp_urlmap"
    end

    test "quick_generate for gcp produces snapshot with both artifact separator headers",
         %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # Trigger quick_generate for gcp
      lv
      |> element(~s(button[phx-value-provider="gcp"]))
      |> render_click()

      # Retrieve the stored snapshot
      snap = Snapshots.latest_snapshot(app, "gcp")
      assert snap != nil

      output = Snapshots.decrypt_output(snap)
      assert output =~ "gcp-armor.json"
      assert output =~ "gcp-urlmap.json"
      assert output =~ "Cloud Armor"
      assert output =~ "URL Map"
    end

    test "combined gcp output splits into exactly two artifacts", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      lv
      |> element(~s(button[phx-value-provider="gcp"]))
      |> render_click()

      snap = Snapshots.latest_snapshot(app, "gcp")
      output = Snapshots.decrypt_output(snap)
      artifacts = Multi.split_artifacts(output)

      assert length(artifacts) == 2
      labels = Enum.map(artifacts, fn {label, _filename, _content} -> label end)
      assert "Cloud Armor" in labels
      assert "URL Map" in labels
    end

    test "gcp config fields include allow_ip_ranges and allow_regions as textarea type",
         %{conn: _conn, app: _app} do
      fields = WaggerWeb.AppDetailLive.config_fields_for("gcp")
      types = Map.new(fields, fn {key, _label, type} -> {key, type} end)

      assert types["allow_ip_ranges"] == :textarea
      assert types["allow_regions"] == :textarea
      assert types["prefix"] == :text
      assert types["known_traffic_backend"] == :text
      assert types["deny_backend"] == :text
    end
  end

  describe "Request lookup panel" do
    test "renders the lookup panel with method dropdown and path input", %{conn: conn, app: app} do
      {:ok, _lv, html} = live(conn, ~p"/applications/#{app.id}")

      assert html =~ "Request Lookup"
      assert html =~ "GET"
      assert html =~ ~s(placeholder="/api/users/123")
    end

    test "submitting GET /api/users returns :allowed verdict", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      html = lv |> form("form[phx-change=lookup_request]", %{method: "GET", path: "/api/users"}) |> render_change()

      assert html =~ "ALLOWED"
      assert html =~ "/api/users"
    end

    test "submitting DELETE /api/users returns :method_not_allowed (route only allows GET/POST)",
         %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      html =
        lv
        |> form("form[phx-change=lookup_request]", %{method: "DELETE", path: "/api/users"})
        |> render_change()

      assert html =~ "METHOD NOT ALLOWED"
    end

    test "submitting a path with no matching route returns :not_in_allowlist",
         %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      html =
        lv
        |> form("form[phx-change=lookup_request]", %{method: "GET", path: "/totally/unknown"})
        |> render_change()

      assert html =~ "NOT IN ALLOWLIST"
    end

    test "empty path clears the result", %{conn: conn, app: app} do
      {:ok, lv, _html} = live(conn, ~p"/applications/#{app.id}")

      # First perform a lookup
      lv
      |> form("form[phx-change=lookup_request]", %{method: "GET", path: "/api/users"})
      |> render_change()

      # Now clear the path
      html =
        lv
        |> form("form[phx-change=lookup_request]", %{method: "GET", path: ""})
        |> render_change()

      # Verdict badge should be gone
      refute html =~ "ALLOWED"
      refute html =~ "NOT IN ALLOWLIST"
    end
  end

  describe "Multi.split_artifacts/1" do
    test "returns single element with nil label for non-multi-artifact input" do
      output = ~s({"foo": "bar"})
      assert [{nil, nil, ^output}] = Multi.split_artifacts(output)
    end

    test "correctly round-trips two artifacts" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact"}]
      modules = [
        {"Cloud Armor", Wagger.Generator.Gcp, "gcp-armor.json"},
        {"URL Map", Wagger.Generator.GcpUrlMap, "gcp-urlmap.json"}
      ]

      {:ok, combined} = Multi.generate(modules, routes, %{prefix: "test"})
      artifacts = Multi.split_artifacts(combined)

      assert length(artifacts) == 2
      {label1, fn1, content1} = Enum.at(artifacts, 0)
      {label2, fn2, content2} = Enum.at(artifacts, 1)

      assert label1 == "Cloud Armor"
      assert fn1 == "gcp-armor.json"
      assert content1 =~ "WAF policy"

      assert label2 == "URL Map"
      assert fn2 == "gcp-urlmap.json"
      assert content2 =~ "defaultService"
    end
  end
end
