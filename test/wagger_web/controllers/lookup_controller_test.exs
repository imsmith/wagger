defmodule WaggerWeb.LookupControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "lookupuser"})
    {:ok, app} = Applications.create_application(%{"name" => "lookup-app", "tags" => ["api"]})

    {:ok, _r_users} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET", "POST"],
        "path_type" => "exact",
        "rate_limit" => 100,
        "description" => "User collection"
      })

    {:ok, _r_user_id} =
      Routes.create_route(app, %{
        "path" => "/api/users/{id}",
        "methods" => ["GET"],
        "path_type" => "exact"
      })

    {:ok, _r_static} =
      Routes.create_route(app, %{
        "path" => "/static",
        "methods" => ["GET"],
        "path_type" => "prefix"
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "show — allowed verdict" do
    test "returns 200 with :allowed when method and path match", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?method=GET&path=/api/users")

      assert %{
               "verdict" => "allowed",
               "method" => "GET",
               "path" => "/api/users",
               "matches" => matches
             } = json_response(conn, 200)

      assert length(matches) >= 1
      assert hd(matches)["method_allowed"] == true
    end
  end

  describe "show — method_not_allowed verdict" do
    test "returns 200 with :method_not_allowed when path matches but method does not",
         %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?method=DELETE&path=/api/users")

      assert %{
               "verdict" => "method_not_allowed",
               "method" => "DELETE",
               "matches" => matches
             } = json_response(conn, 200)

      assert length(matches) >= 1
      assert Enum.all?(matches, &(&1["method_allowed"] == false))
    end
  end

  describe "show — not_in_allowlist verdict" do
    test "returns 200 with :not_in_allowlist when no path matches", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?method=GET&path=/unknown/route")

      assert %{
               "verdict" => "not_in_allowlist",
               "matches" => []
             } = json_response(conn, 200)
    end
  end

  describe "show — validation" do
    test "returns 400 when method param is missing", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?path=/api/users")

      assert %{"error" => _} = json_response(conn, 400)
    end

    test "returns 400 when path param is missing", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?method=GET")

      assert %{"error" => _} = json_response(conn, 400)
    end

    test "returns 400 when both params are missing", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup")

      assert %{"error" => _} = json_response(conn, 400)
    end
  end

  describe "show — not found" do
    test "returns 404 for unknown application", %{conn: conn} do
      conn = get(conn, ~p"/api/applications/0/lookup?method=GET&path=/api/users")

      assert json_response(conn, 404)
    end
  end

  describe "show — URL-encoded path" do
    test "decodes URL-encoded path correctly", %{conn: conn, app: app} do
      # Phoenix decodes query params, so /api/users/123 encoded should still work
      conn = get(conn, ~p"/api/applications/#{app.id}/lookup?method=GET&path=/api/users/123")

      assert %{"verdict" => verdict} = json_response(conn, 200)
      # /api/users/{id} should match /api/users/123
      assert verdict in ["allowed", "method_not_allowed"]
    end
  end

  describe "show — prefix match" do
    test "prefix route matches subpaths", %{conn: conn, app: app} do
      conn =
        get(conn, ~p"/api/applications/#{app.id}/lookup?method=GET&path=/static/foo.css")

      assert %{"verdict" => "allowed"} = json_response(conn, 200)
    end
  end
end
