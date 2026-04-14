defmodule Wagger.Generator.PathHelperTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator.PathHelper

  describe "to_regex/1" do
    test "exact path without params returns anchored regex" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/users$"
    end

    test "exact path with params converts {param} to [^/]+" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/users/[^/]+$"
    end

    test "prefix path without trailing slash gets wildcard" do
      route = %{path: "/static", path_type: "prefix"}
      assert PathHelper.to_regex(route) == "^/static.*"
    end

    test "prefix path gets trailing wildcard" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_regex(route) == "^/static/.*"
    end

    test "regex path passes through unchanged" do
      route = %{path: "^/api/v[12]/.*", path_type: "regex"}
      assert PathHelper.to_regex(route) == "^/api/v[12]/.*"
    end

    test "path with multiple params converts all" do
      route = %{path: "/api/{version}/users/{id}", path_type: "exact"}
      assert PathHelper.to_regex(route) == "^/api/[^/]+/users/[^/]+$"
    end
  end

  describe "to_wildcard/1" do
    test "exact path without params returns path unchanged" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_wildcard(route) == "/api/users"
    end

    test "exact path with params converts {param} to *" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_wildcard(route) == "/api/users/*"
    end

    test "prefix path gets trailing wildcard" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_wildcard(route) == "/static/*"
    end

    test "prefix path without trailing slash gets it added with wildcard" do
      route = %{path: "/static", path_type: "prefix"}
      assert PathHelper.to_wildcard(route) == "/static/*"
    end

    test "path with multiple params converts all to single *" do
      route = %{path: "/api/{version}/users/{id}", path_type: "exact"}
      assert PathHelper.to_wildcard(route) == "/api/*/users/*"
    end
  end

  describe "to_nginx_location/1" do
    test "exact path without params returns exact tuple" do
      route = %{path: "/api/users", path_type: "exact"}
      assert PathHelper.to_nginx_location(route) == {:exact, "/api/users"}
    end

    test "exact path with params returns regex tuple" do
      route = %{path: "/api/users/{id}", path_type: "exact"}
      assert PathHelper.to_nginx_location(route) == {:regex, "^/api/users/[^/]+$"}
    end

    test "prefix path returns prefix tuple with trailing slash" do
      route = %{path: "/static", path_type: "prefix"}
      assert PathHelper.to_nginx_location(route) == {:prefix, "/static/"}
    end

    test "prefix path with trailing slash returns prefix tuple" do
      route = %{path: "/static/", path_type: "prefix"}
      assert PathHelper.to_nginx_location(route) == {:prefix, "/static/"}
    end

    test "regex path returns regex tuple with pattern" do
      route = %{path: "^/api/v[12]/.*", path_type: "regex"}
      assert PathHelper.to_nginx_location(route) == {:regex, "^/api/v[12]/.*"}
    end

    test "exact path with multiple params returns regex" do
      route = %{path: "/api/{version}/users/{id}", path_type: "exact"}
      assert PathHelper.to_nginx_location(route) == {:regex, "^/api/[^/]+/users/[^/]+$"}
    end
  end
end
