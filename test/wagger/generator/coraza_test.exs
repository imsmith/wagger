defmodule Wagger.Generator.CorazaTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Coraza

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health"}
  ]

  @config %{prefix: "myapp"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "produces instance with config-name matching prefix" do
      instance = Coraza.map_routes(@routes, @config)
      assert instance["coraza-config"]["config-name"] == "myapp"
    end

    test "rule IDs increment sequentially from default start" do
      instance = Coraza.map_routes(@routes, @config)
      ids = instance["coraza-config"]["rules"] |> Enum.map(& &1["id"])
      assert ids == [100_001, 100_002, 100_003, 100_004]
    end

    test "custom start_rule_id is respected" do
      config = Map.put(@config, :start_rule_id, 200_001)
      instance = Coraza.map_routes(@routes, config)
      ids = instance["coraza-config"]["rules"] |> Enum.map(& &1["id"])
      assert ids == [200_001, 200_002, 200_003, 200_004]
    end

    test "catch-all rule ID is start + 90000" do
      instance = Coraza.map_routes(@routes, @config)
      assert instance["coraza-config"]["catch-all-rule-id"] == 190_001
    end

    test "catch-all rule ID respects custom start" do
      config = Map.put(@config, :start_rule_id, 200_001)
      instance = Coraza.map_routes(@routes, config)
      assert instance["coraza-config"]["catch-all-rule-id"] == 290_001
    end

    test "path patterns are correct regexes" do
      instance = Coraza.map_routes(@routes, @config)
      patterns = instance["coraza-config"]["rules"] |> Enum.map(& &1["path-pattern"])
      assert "^/api/users$" in patterns
      assert "^/api/users/[^/]+$" in patterns
      assert "^/static/.*" in patterns
      assert "^/health$" in patterns
    end

    test "methods lists match route methods" do
      instance = Coraza.map_routes(@routes, @config)
      rules = instance["coraza-config"]["rules"]
      users = Enum.find(rules, &(&1["path-pattern"] == "^/api/users$"))
      assert users["methods"] == ["GET", "POST"]
    end

    test "rate-limit comment present when route has rate limit" do
      instance = Coraza.map_routes(@routes, @config)
      rules = instance["coraza-config"]["rules"]
      users = Enum.find(rules, &(&1["path-pattern"] == "^/api/users$"))
      assert users["rate-limit-comment"] =~ "100 req/min"
    end

    test "rate-limit comment absent when route has no rate limit" do
      instance = Coraza.map_routes(@routes, @config)
      rules = instance["coraza-config"]["rules"]
      health = Enum.find(rules, &(&1["path-pattern"] == "^/health$"))
      refute Map.has_key?(health, "rate-limit-comment")
    end

    test "description present when route has one" do
      instance = Coraza.map_routes(@routes, @config)
      rules = instance["coraza-config"]["rules"]
      users = Enum.find(rules, &(&1["path-pattern"] == "^/api/users$"))
      assert users["description"] == "Users"
    end

    test "default rule-engine is On" do
      instance = Coraza.map_routes(@routes, @config)
      assert instance["coraza-config"]["rule-engine"] == "On"
    end

    test "custom rule-engine mode" do
      config = Map.put(@config, :rule_engine, "DetectionOnly")
      instance = Coraza.map_routes(@routes, config)
      assert instance["coraza-config"]["rule-engine"] == "DetectionOnly"
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "generates valid SecRule config with engine directives" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ "SecRuleEngine On"
      assert output =~ "SecRequestBodyAccess On"
      assert output =~ ~s(SecDefaultAction "phase:1,log,auditlog,deny,status:403")
    end

    test "each route produces a SecRule REQUEST_URI line" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ ~s(SecRule REQUEST_URI "@rx ^/api/users$")
      assert output =~ ~s(SecRule REQUEST_URI "@rx ^/api/users/[^/]+$")
      assert output =~ ~s(SecRule REQUEST_URI "@rx ^/static/.*")
      assert output =~ ~s(SecRule REQUEST_URI "@rx ^/health$")
    end

    test "each route has chained method enforcement" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ ~s(SecRule REQUEST_METHOD "@pm GET POST" "t:none")
      assert output =~ ~s(SecRule REQUEST_METHOD "@pm GET PUT DELETE" "t:none")
      assert output =~ ~s(SecRule REQUEST_METHOD "@pm GET" "t:none")
    end

    test "rule IDs appear in output" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ "id:100001"
      assert output =~ "id:100002"
      assert output =~ "id:100003"
      assert output =~ "id:100004"
    end

    test "catch-all deny rule present at end" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ "# Deny all undeclared paths"
      assert output =~ ~s(id:190001,phase:1,deny,status:403,msg:'No matching route')
    end

    test "rate-limit comments appear for rate-limited routes" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ "# Rate limit: 100 req/min"
    end

    test "rate-limit comments absent for non-rate-limited routes" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      # Health route has no rate limit — check that the output around it has no rate comment
      lines = String.split(output, "\n")
      health_idx = Enum.find_index(lines, &String.contains?(&1, "/health"))
      # The line before the SecRule for /health should be a route comment, not a rate comment
      prev_line = Enum.at(lines, health_idx - 1)
      refute prev_line =~ "Rate limit"
    end

    test "DetectionOnly mode produces correct engine directive" do
      config = Map.put(@config, :rule_engine, "DetectionOnly")
      assert {:ok, output} = Generator.generate(Coraza, @routes, config)
      assert output =~ "SecRuleEngine DetectionOnly"
    end

    test "header includes app name" do
      assert {:ok, output} = Generator.generate(Coraza, @routes, @config)
      assert output =~ "# Generated by Wagger for app: myapp"
    end
  end
end
