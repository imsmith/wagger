defmodule Wagger.Generator.CaddyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Caddy

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]

  @config %{prefix: "myapp", upstream: "http://backend:8080"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "creates route entries for each route" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      assert length(matchers) == 4
    end

    test "uses path matcher for exact routes without params" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      users = Enum.find(matchers, &(&1["name"] == "api_users"))
      assert users["match-type"] == "path"
      assert users["pattern"] == "/api/users"
    end

    test "uses path_regexp matcher for routes with params" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      user_detail = Enum.find(matchers, &(&1["name"] == "api_users__id"))
      assert user_detail["match-type"] == "path_regexp"
      assert user_detail["pattern"] =~ "api/users"
    end

    test "includes rate limit for rate-limited routes" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      users = Enum.find(matchers, &(&1["name"] == "api_users"))
      assert Map.has_key?(users, "rate-limit")
      assert users["rate-limit"]["per-minute"] == 100
    end

    test "omits rate-limit key for non-rate-limited routes" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      health = Enum.find(matchers, &(&1["name"] == "health"))
      refute Map.has_key?(health, "rate-limit")
    end

    test "stores allowed methods in matcher" do
      instance = Caddy.map_routes(@routes, @config)
      matchers = instance["caddy-config"]["matchers"]
      users = Enum.find(matchers, &(&1["name"] == "api_users"))
      assert users["allowed-methods"] == ["GET", "POST"]
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "generates Caddyfile with @ matchers" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "@api_users"
      assert output =~ "@health"
    end

    test "uses path matcher for exact routes without params" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "path /api/users"
    end

    test "uses path_regexp matcher for parameterised routes" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "path_regexp"
      assert output =~ "api/users"
    end

    test "uses path wildcard matcher for prefix routes" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "path /static/*"
    end

    test "contains method restrictions in matchers" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "method GET POST"
      assert output =~ "method GET PUT DELETE"
      assert output =~ "method GET"
    end

    test "contains reverse_proxy directives" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      reverse_proxy_count = output |> String.split("reverse_proxy") |> length() |> Kernel.-(1)
      assert reverse_proxy_count == length(@routes)
    end

    test "contains rate_limit block for rate-limited routes" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "rate_limit {per_minute 100}"
    end

    test "ends with respond 403 catch-all" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "respond 403"
    end

    test "route blocks reference named matchers" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "route @api_users {"
      assert output =~ "route @health {"
    end
  end
end
