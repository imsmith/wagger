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

    test "rejects invalid regex when path_type is regex", %{app: app} do
      attrs = %{"path" => "^/api/(unclosed", "path_type" => "regex", "methods" => ["GET"]}
      assert {:error, changeset} = Routes.create_route(app, attrs)
      assert %{path: [msg]} = errors_on(changeset)
      assert msg =~ "invalid regex"
    end

    test "accepts valid regex when path_type is regex", %{app: app} do
      attrs = %{"path" => "^/api/v[12]/.*$", "path_type" => "regex", "methods" => ["GET"]}
      assert {:ok, _route} = Routes.create_route(app, attrs)
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

  describe "lookup_for_request/3" do
    setup %{app: app} do
      {:ok, r_users} =
        Routes.create_route(app, %{
          "path" => "/api/users",
          "methods" => ["GET", "POST"],
          "path_type" => "exact",
          "rate_limit" => 100,
          "description" => "User collection"
        })

      {:ok, r_user_id} =
        Routes.create_route(app, %{
          "path" => "/api/users/{id}",
          "methods" => ["GET", "PUT", "DELETE"],
          "path_type" => "exact"
        })

      {:ok, r_static} =
        Routes.create_route(app, %{
          "path" => "/static",
          "methods" => ["GET"],
          "path_type" => "prefix"
        })

      {:ok, r_regex} =
        Routes.create_route(app, %{
          "path" => "^/api/v[12]/.*",
          "methods" => ["GET", "POST"],
          "path_type" => "regex"
        })

      {:ok, routes: %{users: r_users, user_id: r_user_id, static: r_static, regex: r_regex}}
    end

    test "returns :allowed when path and method match", %{app: app} do
      result = Routes.lookup_for_request(app, "GET", "/api/users")

      assert result.verdict == :allowed
      assert result.method == "GET"
      assert result.path == "/api/users"
      assert length(result.matches) >= 1
      assert hd(result.matches).method_allowed == true
    end

    test "returns :method_not_allowed when path matches but method does not", %{app: app} do
      result = Routes.lookup_for_request(app, "DELETE", "/api/users")

      assert result.verdict == :method_not_allowed
      assert result.method == "DELETE"
      assert length(result.matches) >= 1
      assert Enum.all?(result.matches, &(&1.method_allowed == false))
    end

    test "returns :not_in_allowlist when no path matches", %{app: app} do
      result = Routes.lookup_for_request(app, "GET", "/not/a/known/path")

      assert result.verdict == :not_in_allowlist
      assert result.matches == []
    end

    test "param substitution: /api/users/{id} matches /api/users/123", %{app: app} do
      result = Routes.lookup_for_request(app, "PUT", "/api/users/123")

      assert result.verdict == :allowed
      match = Enum.find(result.matches, &(&1.path == "/api/users/{id}"))
      assert match != nil
      assert match.method_allowed == true
    end

    test "exact path /api/users does not match /api/users/123", %{app: app} do
      result = Routes.lookup_for_request(app, "GET", "/api/users/123")

      # /api/users is exact with no params, should NOT match /api/users/123
      matching_paths = Enum.map(result.matches, & &1.path)
      refute "/api/users" in matching_paths
    end

    test "prefix match: /static prefix matches /static/foo.css", %{app: app} do
      result = Routes.lookup_for_request(app, "GET", "/static/foo.css")

      assert result.verdict == :allowed
      match = Enum.find(result.matches, &(&1.path == "/static"))
      assert match != nil
      assert match.path_type == "prefix"
    end

    test "regex passthrough: ^/api/v[12]/.* matches /api/v1/items", %{app: app} do
      result = Routes.lookup_for_request(app, "POST", "/api/v1/items")

      assert result.verdict == :allowed
      match = Enum.find(result.matches, &(&1.path_type == "regex"))
      assert match != nil
    end

    test "case-insensitive method input: 'get' normalises to 'GET'", %{app: app} do
      result = Routes.lookup_for_request(app, "get", "/api/users")

      assert result.method == "GET"
      assert result.verdict == :allowed
    end

    test "specificity ordering: exact before prefix before regex", %{app: app} do
      # Create an additional route so /api/v1/users matches both a prefix and a regex
      {:ok, _prefix_route} =
        Routes.create_route(app, %{
          "path" => "/api/v1",
          "methods" => ["GET"],
          "path_type" => "prefix"
        })

      result = Routes.lookup_for_request(app, "GET", "/api/v1/users")

      assert length(result.matches) >= 2

      types = Enum.map(result.matches, & &1.path_type)
      prefix_idx = Enum.find_index(types, &(&1 == "prefix"))
      regex_idx = Enum.find_index(types, &(&1 == "regex"))

      # prefix (order 1) should appear before regex (order 2)
      assert prefix_idx < regex_idx
    end

    test "multiple matches with method_allowed flagged correctly", %{app: app, routes: routes} do
      result = Routes.lookup_for_request(app, "GET", "/api/users/123")

      # /api/users/{id} should match
      match = Enum.find(result.matches, &(&1.route_id == routes.user_id.id))
      assert match != nil
      assert match.method_allowed == true
    end

    test "route with truly empty methods list: path matches but method never allowed", %{app: app} do
      # Bypass the changeset default by inserting via Repo with raw SQL-shaped attrs.
      # The changeset rewrites methods=[] to ["GET"]; we want to verify the lookup
      # gracefully handles the stored-empty case (e.g., direct DB writes from data
      # imports that skip changeset validation).
      {:ok, route} =
        Routes.create_route(app, %{
          "path" => "/locked",
          "methods" => ["GET"],
          "path_type" => "exact"
        })

      {1, _} =
        Wagger.Repo.update_all(
          Ecto.Query.from(r in Wagger.Applications.Route, where: r.id == ^route.id),
          set: [methods: []]
        )

      result = Routes.lookup_for_request(app, "GET", "/locked")

      match = Enum.find(result.matches, &(&1.route_id == route.id))
      assert match != nil
      assert match.methods == []
      assert match.method_allowed == false
      assert result.verdict == :method_not_allowed
    end
  end
end
