defmodule Wagger.Import.OpenApiTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Import.OpenApi

  @minimal_spec %{
    "openapi" => "3.0.0",
    "info" => %{"title" => "Test", "version" => "1.0"},
    "paths" => %{
      "/api/users" => %{
        "get" => %{
          "summary" => "List users",
          "parameters" => [
            %{"name" => "page", "in" => "query", "required" => false},
            %{"name" => "Authorization", "in" => "header", "required" => true}
          ]
        },
        "post" => %{"summary" => "Create user"}
      },
      "/api/users/{id}" => %{
        "get" => %{"summary" => "Get user"},
        "put" => %{"summary" => "Update user"},
        "delete" => %{"summary" => "Delete user"}
      }
    }
  }

  describe "parse/1 with map input" do
    setup do
      {routes, errors} = OpenApi.parse(@minimal_spec)
      %{routes: routes, errors: errors}
    end

    test "returns no errors for valid spec", %{errors: errors} do
      assert errors == []
    end

    test "extracts both paths", %{routes: routes} do
      paths = Enum.map(routes, & &1.path) |> Enum.sort()
      assert paths == ["/api/users", "/api/users/{id}"]
    end

    test "extracts methods for /api/users as GET and POST", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users"))
      assert Enum.sort(route.methods) == ["GET", "POST"]
    end

    test "extracts methods for /api/users/{id} as GET, PUT, DELETE", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users/{id}"))
      assert Enum.sort(route.methods) == ["DELETE", "GET", "PUT"]
    end

    test "extracts description from first operation summary", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users"))
      assert route.description in ["List users", "Create user"]
    end

    test "extracts query parameters for /api/users", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users"))
      assert route.query_params == [%{"name" => "page", "required" => false}]
    end

    test "extracts header parameters for /api/users", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users"))
      assert route.headers == [%{"name" => "Authorization", "required" => true}]
    end

    test "preserves {param} path format", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users/{id}"))
      assert route.path == "/api/users/{id}"
    end

    test "all routes have path_type exact", %{routes: routes} do
      assert Enum.all?(routes, &(&1.path_type == "exact"))
    end

    test "route has all required keys", %{routes: routes} do
      route = hd(routes)
      assert Map.has_key?(route, :path)
      assert Map.has_key?(route, :methods)
      assert Map.has_key?(route, :path_type)
      assert Map.has_key?(route, :description)
      assert Map.has_key?(route, :query_params)
      assert Map.has_key?(route, :headers)
    end

    test "/api/users/{id} has no query params", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users/{id}"))
      assert route.query_params == []
    end

    test "/api/users/{id} has no headers", %{routes: routes} do
      route = Enum.find(routes, &(&1.path == "/api/users/{id}"))
      assert route.headers == []
    end
  end

  describe "parse/1 with JSON string input" do
    test "accepts a JSON string and returns routes" do
      json = Jason.encode!(@minimal_spec)
      {routes, errors} = OpenApi.parse(json)
      assert errors == []
      assert length(routes) == 2
    end
  end

  describe "parse/1 error cases" do
    test "returns error for invalid JSON string" do
      {routes, errors} = OpenApi.parse("not valid json {{{")
      assert routes == []
      assert length(errors) == 1
      assert hd(errors) =~ "Invalid JSON:"
    end

    test "returns error for missing paths key" do
      {routes, errors} = OpenApi.parse(%{"openapi" => "3.0.0"})
      assert routes == []
      assert errors == ["No paths found in OpenAPI spec"]
    end
  end
end
