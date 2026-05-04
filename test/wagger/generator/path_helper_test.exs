defmodule Wagger.Generator.PathHelperTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator.PathHelper

  doctest Wagger.Generator.PathHelper

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

  describe "partition_by_method_set/2" do
    test "empty route list returns empty result" do
      result = PathHelper.partition_by_method_set([], & &1.path)
      assert result == []
    end

    test "single route with single method returns one bucket with one path" do
      routes = [%{path: "/a", methods: ["GET"], path_type: "exact"}]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      assert result == [{["GET"], ["/a"]}]
    end

    test "single route with multi-method sorts and deduplicates methods" do
      routes = [%{path: "/a", methods: ["POST", "GET"], path_type: "exact"}]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      assert result == [{["GET", "POST"], ["/a"]}]
    end

    test "two routes same path disjoint methods unions into one bucket" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact"},
        %{path: "/a", methods: ["POST"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      assert result == [{["GET", "POST"], ["/a"]}]
    end

    test "two routes same path overlapping methods deduplicates without double-counting" do
      routes = [
        %{path: "/a", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/a", methods: ["GET"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      assert result == [{["GET", "POST"], ["/a"]}]
    end

    test "routes with distinct method-sets produce distinct buckets sorted deterministically" do
      routes = [
        %{path: "/b", methods: ["POST"], path_type: "exact"},
        %{path: "/a", methods: ["GET"], path_type: "exact"},
        %{path: "/c", methods: ["GET", "POST"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      # Results sorted by method-set: ["GET"], ["GET", "POST"], ["POST"]
      assert result == [
        {["GET"], ["/a"]},
        {["GET", "POST"], ["/c"]},
        {["POST"], ["/b"]}
      ]
    end

    test "mapper projects paths as raw strings" do
      routes = [
        %{path: "/users", methods: ["GET"], path_type: "exact"},
        %{path: "/posts", methods: ["GET"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      [{methods, paths}] = result
      assert methods == ["GET"]
      assert Enum.sort(paths) == ["/posts", "/users"]
    end

    test "mapper applies to_regex projection" do
      routes = [
        %{path: "/users/{id}", methods: ["GET"], path_type: "exact"},
        %{path: "/posts/{id}", methods: ["GET"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, &PathHelper.to_regex/1)
      [{methods, paths}] = result
      assert methods == ["GET"]
      assert Enum.sort(paths) == ["^/posts/[^/]+$", "^/users/[^/]+$"]
    end

    test "mapper applies to_wildcard projection" do
      routes = [
        %{path: "/users/{id}", methods: ["GET"], path_type: "exact"},
        %{path: "/posts/{id}", methods: ["GET"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, &PathHelper.to_wildcard/1)
      [{methods, paths}] = result
      assert methods == ["GET"]
      assert Enum.sort(paths) == ["/posts/*", "/users/*"]
    end

    test "complex scenario: multiple method-sets with multiple paths per set" do
      routes = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/api/posts", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/api/admin", methods: ["DELETE"], path_type: "exact"},
        %{path: "/api/health", methods: ["GET"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      # Buckets sorted by method-set: ["DELETE"], ["GET"], ["GET", "POST"]
      assert length(result) == 3
      [{m1, p1}, {m2, p2}, {m3, p3}] = result
      assert m1 == ["DELETE"]
      assert p1 == ["/api/admin"]
      assert m2 == ["GET"]
      assert p2 == ["/api/health"]
      assert m3 == ["GET", "POST"]
      assert Enum.sort(p3) == ["/api/posts", "/api/users"]
    end

    test "complex deduplication with overlapping method sets" do
      routes = [
        %{path: "/x", methods: ["GET", "POST"], path_type: "exact"},
        %{path: "/y", methods: ["GET"], path_type: "exact"},
        %{path: "/x", methods: ["POST"], path_type: "exact"},
        %{path: "/z", methods: ["GET", "POST"], path_type: "exact"}
      ]
      result = PathHelper.partition_by_method_set(routes, & &1.path)
      # /x should have GET+POST, /y has GET, /z has GET+POST
      assert result == [
        {["GET"], ["/y"]},
        {["GET", "POST"], ["/x", "/z"]}
      ]
    end
  end
end
