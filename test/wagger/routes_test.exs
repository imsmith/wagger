defmodule Wagger.RoutesTest do
  @moduledoc """
  Tests for the Wagger.Routes context module.

  Covers CRUD operations and tag/method/path_type filtering over the routes
  table, scoped to a parent application.
  """

  use Wagger.DataCase

  alias Wagger.Applications
  alias Wagger.Applications.Route
  alias Wagger.Routes

  setup do
    {:ok, app} = Applications.create_application(%{"name" => "test-app"})
    {:ok, app: app}
  end

  @valid_attrs %{
    "path" => "/users",
    "methods" => ["GET", "POST"],
    "path_type" => "exact",
    "description" => "User collection",
    "rate_limit" => 100,
    "tags" => ["public", "api"]
  }

  @update_attrs %{
    "path" => "/users",
    "path_type" => "exact",
    "description" => "Updated description",
    "rate_limit" => 200,
    "tags" => ["internal"]
  }

  describe "create_route/2" do
    test "creates with valid attrs", %{app: app} do
      assert {:ok, %Route{} = route} = Routes.create_route(app, @valid_attrs)
      assert route.path == "/users"
      assert route.methods == ["GET", "POST"]
      assert route.path_type == "exact"
      assert route.description == "User collection"
      assert route.rate_limit == 100
      assert route.tags == ["public", "api"]
      assert route.application_id == app.id
    end

    test "defaults to GET method when methods not provided", %{app: app} do
      attrs = Map.delete(@valid_attrs, "methods")
      assert {:ok, route} = Routes.create_route(app, attrs)
      assert route.methods == ["GET"]
    end

    test "defaults to GET method when methods is empty list", %{app: app} do
      attrs = Map.put(@valid_attrs, "methods", [])
      assert {:ok, route} = Routes.create_route(app, attrs)
      assert route.methods == ["GET"]
    end

    test "rejects duplicate path within same app", %{app: app} do
      assert {:ok, _} = Routes.create_route(app, @valid_attrs)
      assert {:error, changeset} = Routes.create_route(app, @valid_attrs)
      assert %{application_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "allows same path in different apps", %{app: app} do
      {:ok, other_app} = Applications.create_application(%{"name" => "other-app"})
      assert {:ok, _} = Routes.create_route(app, @valid_attrs)
      assert {:ok, _} = Routes.create_route(other_app, @valid_attrs)
    end

    test "requires path", %{app: app} do
      attrs = Map.delete(@valid_attrs, "path")
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert %{path: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires path_type", %{app: app} do
      attrs = Map.delete(@valid_attrs, "path_type")
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert %{path_type: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects invalid path_type", %{app: app} do
      attrs = Map.put(@valid_attrs, "path_type", "invalid")
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert %{path_type: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "list_routes/2" do
    test "returns routes for the app", %{app: app} do
      {:ok, _} = Routes.create_route(app, @valid_attrs)
      {:ok, _} = Routes.create_route(app, Map.put(@valid_attrs, "path", "/posts"))

      routes = Routes.list_routes(app)
      assert length(routes) == 2
    end

    test "does not return routes from other apps", %{app: app} do
      {:ok, other_app} = Applications.create_application(%{"name" => "other-app"})
      {:ok, _} = Routes.create_route(app, @valid_attrs)
      {:ok, _} = Routes.create_route(other_app, @valid_attrs)

      routes = Routes.list_routes(app)
      assert length(routes) == 1
    end

    test "filters by tag", %{app: app} do
      {:ok, _} = Routes.create_route(app, @valid_attrs)

      {:ok, _} =
        Routes.create_route(
          app,
          Map.merge(@valid_attrs, %{"path" => "/private", "tags" => ["internal"]})
        )

      result = Routes.list_routes(app, %{"tag" => "public"})
      assert length(result) == 1
      assert hd(result).path == "/users"
    end

    test "filters by method", %{app: app} do
      {:ok, _} = Routes.create_route(app, @valid_attrs)

      {:ok, _} =
        Routes.create_route(
          app,
          Map.merge(@valid_attrs, %{"path" => "/posts", "methods" => ["DELETE"]})
        )

      result = Routes.list_routes(app, %{"method" => "DELETE"})
      assert length(result) == 1
      assert hd(result).path == "/posts"
    end

    test "filters by path_type", %{app: app} do
      {:ok, _} = Routes.create_route(app, @valid_attrs)

      {:ok, _} =
        Routes.create_route(
          app,
          Map.merge(@valid_attrs, %{"path" => "/v1/*", "path_type" => "prefix"})
        )

      result = Routes.list_routes(app, %{"path_type" => "prefix"})
      assert length(result) == 1
      assert hd(result).path == "/v1/*"
    end

    test "returns empty list when no routes match filter", %{app: app} do
      {:ok, _} = Routes.create_route(app, @valid_attrs)

      result = Routes.list_routes(app, %{"tag" => "nonexistent"})
      assert result == []
    end
  end

  describe "get_route!/2" do
    test "returns the route", %{app: app} do
      {:ok, created} = Routes.create_route(app, @valid_attrs)
      fetched = Routes.get_route!(app, created.id)
      assert fetched.id == created.id
      assert fetched.path == created.path
    end

    test "raises on missing id", %{app: app} do
      assert_raise Ecto.NoResultsError, fn ->
        Routes.get_route!(app, 0)
      end
    end

    test "raises when route belongs to different app", %{app: app} do
      {:ok, other_app} = Applications.create_application(%{"name" => "other-app"})
      {:ok, route} = Routes.create_route(other_app, @valid_attrs)

      assert_raise Ecto.NoResultsError, fn ->
        Routes.get_route!(app, route.id)
      end
    end
  end

  describe "update_route/2" do
    test "updates with valid attrs", %{app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      assert {:ok, updated} = Routes.update_route(route, @update_attrs)
      assert updated.description == "Updated description"
      assert updated.rate_limit == 200
      assert updated.tags == ["internal"]
    end

    test "returns error changeset for invalid attrs", %{app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      assert {:error, changeset} = Routes.update_route(route, %{"path_type" => "invalid"})
      assert %{path_type: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "delete_route/1" do
    test "removes the route", %{app: app} do
      {:ok, route} = Routes.create_route(app, @valid_attrs)
      assert {:ok, %Route{}} = Routes.delete_route(route)

      assert_raise Ecto.NoResultsError, fn ->
        Routes.get_route!(app, route.id)
      end
    end
  end
end
