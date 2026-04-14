defmodule WaggerWeb.ApplicationControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications

  @valid_attrs %{"name" => "my-app", "description" => "Test app", "tags" => ["api"]}
  @invalid_attrs %{"name" => "INVALID NAME"}

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "testuser"})

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn}
  end

  describe "index" do
    test "lists all applications", %{conn: conn} do
      {:ok, _app} = Applications.create_application(@valid_attrs)
      conn = get(conn, ~p"/api/applications")
      assert %{"data" => [_]} = json_response(conn, 200)
    end

    test "filters by tag", %{conn: conn} do
      {:ok, _app1} = Applications.create_application(%{"name" => "tagged-app", "tags" => ["api"]})
      {:ok, _app2} = Applications.create_application(%{"name" => "other-app", "tags" => ["internal"]})

      conn = get(conn, ~p"/api/applications?tag=api")
      response = json_response(conn, 200)
      assert length(response["data"]) == 1
      assert hd(response["data"])["name"] == "tagged-app"
    end
  end

  describe "create" do
    test "creates application with valid data", %{conn: conn} do
      conn = post(conn, ~p"/api/applications", @valid_attrs)
      assert %{"data" => %{"id" => _, "name" => "my-app"}} = json_response(conn, 201)
    end

    test "returns errors with invalid data", %{conn: conn} do
      conn = post(conn, ~p"/api/applications", @invalid_attrs)
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "show" do
    test "shows application", %{conn: conn} do
      {:ok, app} = Applications.create_application(@valid_attrs)
      conn = get(conn, ~p"/api/applications/#{app.id}")
      assert %{"data" => %{"id" => id, "name" => "my-app"}} = json_response(conn, 200)
      assert id == app.id
    end

    test "returns 404 for unknown id", %{conn: conn} do
      conn = get(conn, ~p"/api/applications/0")
      assert json_response(conn, 404)
    end
  end

  describe "update" do
    test "updates application with valid data", %{conn: conn} do
      {:ok, app} = Applications.create_application(@valid_attrs)
      conn = put(conn, ~p"/api/applications/#{app.id}", %{"description" => "Updated"})
      assert %{"data" => %{"description" => "Updated"}} = json_response(conn, 200)
    end
  end

  describe "delete" do
    test "deletes application", %{conn: conn} do
      {:ok, app} = Applications.create_application(@valid_attrs)
      conn = delete(conn, ~p"/api/applications/#{app.id}")
      assert response(conn, 204)
    end
  end

  describe "authentication" do
    test "returns 401 without auth header", %{conn: _conn} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/applications")

      assert json_response(conn, 401)
    end
  end
end
