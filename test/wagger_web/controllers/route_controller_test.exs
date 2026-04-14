defmodule WaggerWeb.RouteControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  @valid_attrs %{
    "path" => "/api/v1/users",
    "methods" => ["GET", "POST"],
    "path_type" => "exact",
    "rate_limit" => 100
  }

  @invalid_attrs %{"path" => nil}

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "testuser"})
    {:ok, app} = Applications.create_application(%{"name" => "test-app", "tags" => ["api"]})

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "index" do
    test "lists routes for application", %{conn: conn, app: app} do
      {:ok, _route} = Routes.create_route(app, @valid_attrs)
      conn = get(conn, ~p"/api/applications/#{app.id}/routes")
      assert %{"data" => [_]} = json_response(conn, 200)
    end

    test "filters by tag", %{conn: conn, app: app} do
      {:ok, _r1} = Routes.create_route(app, Map.merge(@valid_attrs, %{"tags" => ["public"], "path" => "/public"}))
      {:ok, _r2} = Routes.create_route(app, Map.merge(@valid_attrs, %{"tags" => ["internal"], "path" => "/internal"}))

      conn = get(conn, ~p"/api/applications/#{app.id}/routes?tag=public")
      response = json_response(conn, 200)
      assert length(response["data"]) == 1
      assert hd(response["data"])["path"] == "/public"
    end
  end

  describe "create" do
    test "creates route with valid data", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/routes", @valid_attrs)
      assert %{"data" => %{"id" => _, "path" => "/api/v1/users"}} = json_response(conn, 201)
    end

    test "returns errors with invalid data", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/routes", @invalid_attrs)
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "show" do
    test "shows route", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      conn = get(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}")
      assert %{"data" => %{"id" => id, "path" => "/api/v1/users"}} = json_response(conn, 200)
      assert id == route.id
    end

    test "returns 404 for unknown id", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/routes/0")
      assert json_response(conn, 404)
    end
  end

  describe "update" do
    test "updates route with valid data", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      conn = put(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}", %{"path" => "/api/v2/users"})
      assert %{"data" => %{"path" => "/api/v2/users"}} = json_response(conn, 200)
    end
  end

  describe "delete" do
    test "deletes route", %{conn: conn, app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      conn = delete(conn, ~p"/api/applications/#{app.id}/routes/#{route.id}")
      assert response(conn, 204)
    end
  end
end
