defmodule WaggerWeb.ImportControllerTest do
  @moduledoc false

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Applications
  alias Wagger.Routes

  @openapi_spec %{
    "paths" => %{
      "/api/users" => %{
        "get" => %{"summary" => "List users"}
      }
    }
  }

  @accesslog_body ~s(127.0.0.1 - - [01/Jan/2024:00:00:00 +0000] "GET /api/users HTTP/1.1" 200 512)

  setup %{conn: conn} do
    {:ok, _user, api_key} = Accounts.create_user(%{"username" => "importuser"})
    {:ok, app} = Applications.create_application(%{"name" => "import-app", "tags" => ["api"]})

    authed_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{api_key}")

    {:ok, conn: authed_conn, app: app}
  end

  describe "bulk" do
    test "returns preview with parsed routes, token, and empty conflicts/skipped", %{
      conn: conn,
      app: app
    } do
      conn =
        post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{
          "body" => "GET /api/users - List users\nPOST /api/items - Create item"
        })

      assert %{
               "preview_token" => token,
               "parsed" => parsed,
               "conflicts" => [],
               "skipped" => []
             } = json_response(conn, 200)

      assert is_binary(token) and token != ""
      assert length(parsed) == 2
      assert Enum.any?(parsed, &(&1["path"] == "/api/users"))
      assert Enum.any?(parsed, &(&1["path"] == "/api/items"))
    end

    test "detects conflicts with existing routes", %{conn: conn, app: app} do
      {:ok, _route} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "methods" => ["GET"],
          "path_type" => "exact"
        })

      conn =
        post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{
          "body" => "GET,POST /api/users - User endpoint"
        })

      assert %{"conflicts" => conflicts} = json_response(conn, 200)
      assert length(conflicts) == 1
      assert hd(conflicts)["path"] == "/api/users"
    end
  end

  describe "openapi" do
    test "returns preview from OpenAPI spec", %{conn: conn, app: app} do
      conn =
        post(conn, ~p"/api/applications/#{app.id}/import/openapi", %{"spec" => @openapi_spec})

      assert %{
               "preview_token" => token,
               "parsed" => parsed,
               "conflicts" => _,
               "skipped" => _
             } = json_response(conn, 200)

      assert is_binary(token) and token != ""
      assert length(parsed) == 1
      assert hd(parsed)["path"] == "/api/users"
      assert hd(parsed)["methods"] == ["GET"]
    end
  end

  describe "accesslog" do
    test "returns preview from access log", %{conn: conn, app: app} do
      conn =
        post(conn, ~p"/api/applications/#{app.id}/import/accesslog", %{"body" => @accesslog_body})

      assert %{
               "preview_token" => token,
               "parsed" => parsed,
               "conflicts" => _,
               "skipped" => _
             } = json_response(conn, 200)

      assert is_binary(token) and token != ""
      assert length(parsed) == 1
      assert hd(parsed)["path"] == "/api/users"
    end
  end

  describe "confirm" do
    test "inserts routes from valid preview and returns 201", %{conn: conn, app: app} do
      # Step 1: get a preview via bulk
      preview_conn =
        post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{
          "body" => "GET /api/confirmed - Confirmed route"
        })

      preview_resp = json_response(preview_conn, 200)

      # Step 2: confirm with the token and parsed routes
      confirm_conn =
        post(conn, ~p"/api/applications/#{app.id}/import/confirm", %{
          "parsed" => preview_resp["parsed"],
          "preview_token" => preview_resp["preview_token"]
        })

      assert %{"inserted" => inserted} = json_response(confirm_conn, 201)
      assert length(inserted) == 1
      assert hd(inserted)["path"] == "/api/confirmed"
      assert is_integer(hd(inserted)["id"])
    end

    test "returns 422 when preview token is tampered", %{conn: conn, app: app} do
      preview_conn =
        post(conn, ~p"/api/applications/#{app.id}/import/bulk", %{
          "body" => "GET /api/secret - Secret route"
        })

      preview_resp = json_response(preview_conn, 200)

      # Tamper: add an extra route that wasn't in the original preview
      tampered_parsed =
        preview_resp["parsed"] ++
          [%{"path" => "/api/injected", "methods" => ["DELETE"], "path_type" => "exact", "description" => nil}]

      confirm_conn =
        post(conn, ~p"/api/applications/#{app.id}/import/confirm", %{
          "parsed" => tampered_parsed,
          "preview_token" => preview_resp["preview_token"]
        })

      assert %{"error" => _} = json_response(confirm_conn, 422)
    end
  end
end
