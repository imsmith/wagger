defmodule Wagger.Generator.ZapTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Zap

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health"}
  ]

  @config %{prefix: "myapp", target_url: "https://staging.example.com"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "produces instance with config-name matching prefix" do
      instance = Zap.map_routes(@routes, @config)
      assert instance["zap-config"]["config-name"] == "myapp"
    end

    test "target-url is set from config" do
      instance = Zap.map_routes(@routes, @config)
      assert instance["zap-config"]["target-url"] == "https://staging.example.com"
    end

    test "target-url defaults to placeholder when not provided" do
      instance = Zap.map_routes(@routes, %{prefix: "myapp"})
      assert instance["zap-config"]["target-url"] == "{{TARGET_URL}}"
    end

    test "trailing slash stripped from target URL" do
      config = %{prefix: "myapp", target_url: "https://staging.example.com/"}
      instance = Zap.map_routes(@routes, config)
      assert instance["zap-config"]["target-url"] == "https://staging.example.com"
    end

    test "positive tests: one per route per allowed method" do
      instance = Zap.map_routes(@routes, @config)
      positive = instance["zap-config"]["positive-tests"]
      # /api/users: GET, POST (2) + /api/users/{id}: GET, PUT, DELETE (3) + /static/: GET (1) + /health: GET (1) = 7
      assert length(positive) == 7
    end

    test "positive tests use expanded path params" do
      instance = Zap.map_routes(@routes, @config)
      positive = instance["zap-config"]["positive-tests"]
      urls = Enum.map(positive, & &1["url"])
      assert "https://staging.example.com/api/users/1" in urls
      refute Enum.any?(urls, &String.contains?(&1, "{id}"))
    end

    test "positive tests prepend target URL" do
      instance = Zap.map_routes(@routes, @config)
      positive = instance["zap-config"]["positive-tests"]
      assert Enum.all?(positive, &String.starts_with?(&1["url"], "https://staging.example.com"))
    end

    test "negative method tests: disallowed methods per route" do
      instance = Zap.map_routes(@routes, @config)
      negative = instance["zap-config"]["negative-method-tests"]
      # /api/users allows GET,POST → 5 disallowed
      # /api/users/{id} allows GET,PUT,DELETE → 4 disallowed
      # /static/ allows GET → 6 disallowed
      # /health allows GET → 6 disallowed
      # Total: 5 + 4 + 6 + 6 = 21
      assert length(negative) == 21
    end

    test "negative method tests contain correct disallowed methods" do
      instance = Zap.map_routes(@routes, @config)
      negative = instance["zap-config"]["negative-method-tests"]
      users_methods = negative
        |> Enum.filter(&(&1["url"] == "https://staging.example.com/api/users"))
        |> Enum.map(& &1["method"])
        |> Enum.sort()
      assert users_methods == ~w(DELETE HEAD OPTIONS PATCH PUT)
    end

    test "negative path tests: fixed set of synthetic bad paths" do
      instance = Zap.map_routes(@routes, @config)
      negative_path = instance["zap-config"]["negative-path-tests"]
      assert length(negative_path) == 4
      urls = Enum.map(negative_path, & &1["url"])
      assert "https://staging.example.com/nonexistent" in urls
      assert "https://staging.example.com/api/../etc/passwd" in urls
      assert "https://staging.example.com//double-slash" in urls
      assert "https://staging.example.com/%00null" in urls
    end

    test "negative path tests all use GET method" do
      instance = Zap.map_routes(@routes, @config)
      negative_path = instance["zap-config"]["negative-path-tests"]
      assert Enum.all?(negative_path, &(&1["method"] == "GET"))
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "generates valid YAML with env section" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ "env:"
      assert output =~ "contexts:"
      assert output =~ ~s(name: "myapp-waf-verify")
      assert output =~ ~s("https://staging.example.com")
    end

    test "contains all three requestor jobs" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ ~s(name: "waf-positive-tests")
      assert output =~ ~s(name: "waf-negative-method-tests")
      assert output =~ ~s(name: "waf-negative-path-tests")
    end

    test "positive tests use !403 response code" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      # Find lines in positive section
      assert output =~ ~s(responseCode: "!403")
    end

    test "negative tests use 403 response code" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ ~s(responseCode: "403")
    end

    test "path params are expanded in URLs" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ "https://staging.example.com/api/users/1"
      # URLs should not contain {id}, but descriptions may reference the original path
      refute output =~ ~s(url: "https://staging.example.com/api/users/{id}")
    end

    test "synthetic bad paths present in output" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ "/nonexistent"
      assert output =~ "/api/../etc/passwd"
      assert output =~ "//double-slash"
      assert output =~ "/%00null"
    end

    test "header includes app name" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ "# ZAP automation plan for myapp"
    end

    test "placeholder target URL when not provided" do
      config = %{prefix: "myapp"}
      assert {:ok, output} = Generator.generate(Zap, @routes, config)
      assert output =~ "{{TARGET_URL}}"
    end

    test "descriptions appear as comments" do
      assert {:ok, output} = Generator.generate(Zap, @routes, @config)
      assert output =~ "should be allowed"
      assert output =~ "should be blocked"
    end
  end
end
