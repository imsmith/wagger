defmodule WaggerWeb.ExportControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "exportuser"})
    {:ok, app} = Applications.create_application(%{"name" => "export-app", "tags" => ["api"]})

    {:ok, _route} =
      Routes.create_route(app, %{
        "path" => "/api/users",
        "methods" => ["GET", "POST"],
        "path_type" => "exact",
        "description" => "User endpoint",
        "rate_limit" => 100,
        "tags" => ["api"]
      })

    authed_conn =
      conn
      |> put_req_header("accept", "application/edn")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "show" do
    test "returns 200 with application/edn content type", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/export")
      assert response(conn, 200)
      assert response_content_type(conn, :edn) =~ "application/edn"
    end

    test "returns EDN body with route data", %{conn: conn, app: app} do
      conn = get(conn, ~p"/api/applications/#{app.id}/export")
      body = response(conn, 200)
      assert body =~ ~s(:version "1.0")
      assert body =~ ~s(:path "/api/users")
      assert body =~ ":methods [:GET :POST]"
      assert body =~ ":rate-limit 100"
      assert body =~ ":path-type :exact"
    end
  end
end
