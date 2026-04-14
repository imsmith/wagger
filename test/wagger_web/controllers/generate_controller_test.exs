defmodule WaggerWeb.GenerateControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes
  alias Wagger.Snapshots

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "genuser"})
    {:ok, app} = Applications.create_application(%{"name" => "gen-app", "tags" => ["api"]})

    {:ok, _r1} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET", "POST"],
        "path_type" => "exact",
        "rate_limit" => 100
      })

    {:ok, _r2} =
      Routes.create_route(app, %{
        "path" => "/api/items",
        "methods" => ["GET"],
        "path_type" => "prefix"
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "create — nginx" do
    test "returns output containing nginx map directive and stores a snapshot", %{
      conn: conn,
      app: app
    } do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/nginx", %{"prefix" => "test"})

      assert %{
               "output" => output,
               "provider" => "nginx",
               "snapshot_id" => snapshot_id
             } = json_response(conn, 200)

      assert is_binary(output)
      assert output =~ "map $request_uri"
      assert is_integer(snapshot_id)

      snapshots = Snapshots.list_snapshots(app)
      assert length(snapshots) == 1
      assert hd(snapshots).id == snapshot_id
      assert hd(snapshots).provider == "nginx"
    end
  end

  describe "create — aws" do
    test "returns output containing web-acl", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/aws", %{})

      assert %{
               "output" => output,
               "provider" => "aws",
               "snapshot_id" => snapshot_id
             } = json_response(conn, 200)

      assert output =~ "web-acl"
      assert is_integer(snapshot_id)
    end
  end

  describe "create — cloudflare" do
    test "returns provider cloudflare in response", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/cloudflare", %{"prefix" => "test"})

      assert %{
               "provider" => "cloudflare",
               "snapshot_id" => snapshot_id
             } = json_response(conn, 200)

      assert is_integer(snapshot_id)
    end
  end

  describe "create — unknown provider" do
    test "returns 400 with error message", %{conn: conn, app: app} do
      conn = post(conn, ~p"/api/applications/#{app.id}/generate/bogus", %{})

      assert %{"error" => error} = json_response(conn, 400)
      assert error =~ "Unknown provider: bogus"
    end
  end
end
