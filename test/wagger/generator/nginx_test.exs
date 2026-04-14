defmodule Wagger.Generator.NginxTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Nginx

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health"}
  ]

  @config %{prefix: "myapp", upstream: "http://backend:8080"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "produces instance with config-name matching prefix" do
      instance = Nginx.map_routes(@routes, @config)
      assert instance["nginx-config"]["config-name"] == "myapp"
    end

    test "path map has correct number of entries" do
      instance = Nginx.map_routes(@routes, @config)
      entries = instance["nginx-config"]["path-map"]["entries"]
      assert length(entries) == length(@routes)
    end

    test "path map entries have correct patterns" do
      instance = Nginx.map_routes(@routes, @config)
      patterns = instance["nginx-config"]["path-map"]["entries"] |> Enum.map(& &1["pattern"])
      assert "^/api/users$" in patterns
      assert "^/api/users/[^/]+$" in patterns
      assert "^/static/.*" in patterns
      assert "^/health$" in patterns
    end

    test "locations have correct match-types" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]

      # /api/users — exact, no params → exact
      users = Enum.find(locations, &(&1["path"] == "/api/users"))
      assert users["match-type"] == "exact"

      # /api/users/{id} — exact with params → regex
      user_detail = Enum.find(locations, &(&1["path"] == "^/api/users/[^/]+$"))
      assert user_detail["match-type"] == "regex"

      # /static/ — prefix → prefix
      static = Enum.find(locations, &(&1["path"] == "/static/"))
      assert static["match-type"] == "prefix"
    end

    test "rate-limited route has rate-limit container" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]
      users = Enum.find(locations, &(&1["path"] == "/api/users"))
      assert Map.has_key?(users, "rate-limit")
      rate_limit = users["rate-limit"]
      assert rate_limit["zone-name"] =~ "myapp"
      assert is_integer(rate_limit["burst"])
      assert rate_limit["burst"] >= 1
    end

    test "non-rate-limited route omits rate-limit key entirely" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]
      health = Enum.find(locations, &(&1["path"] == "/health"))
      refute Map.has_key?(health, "rate-limit")
    end

    test "burst is 20% of rate_limit floored to integer, min 1" do
      instance = Nginx.map_routes(@routes, @config)
      locations = instance["nginx-config"]["locations"]
      users = Enum.find(locations, &(&1["path"] == "/api/users"))
      # rate_limit=100, burst = max(1, trunc(100 * 0.2)) = 20
      assert users["rate-limit"]["burst"] == 20
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "generates valid nginx config containing map directive and location blocks" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "map $request_uri $valid_path"
      assert output =~ "location"
    end

    test "contains correct location directives: = for exact, ~ for regex, bare for prefix" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      # exact match for /api/users
      assert output =~ "location = /api/users"
      # regex match for parameterised path
      assert output =~ "location ~ ^/api/users/[^/]+"
      # prefix match for /static/
      assert output =~ "location /static/"
    end

    test "contains rate limiting for rate-limited routes" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "limit_req zone=myapp_"
      assert output =~ "burst=20"
      assert output =~ "nodelay"
    end

    test "blocks unknown paths with 403" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "if ($valid_path = 0)"
      assert output =~ "return 403"
    end

    test "map block lists all valid path patterns" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "~^/api/users$"
      assert output =~ "~^/api/users/[^/]+"
      assert output =~ "~^/static/"
      assert output =~ "~^/health$"
    end

    test "location blocks include allowed methods via limit_except" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      assert output =~ "limit_except GET POST"
      assert output =~ "limit_except GET PUT DELETE"
    end

    test "proxy_pass appears in each location block" do
      assert {:ok, output} = Generator.generate(Nginx, @routes, @config)
      proxy_count = output |> String.split("proxy_pass") |> length() |> Kernel.-(1)
      assert proxy_count == length(@routes)
    end
  end
end
