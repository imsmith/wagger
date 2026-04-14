defmodule Wagger.Generator.GcpTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Gcp

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]
  @config %{prefix: "myapp"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "produces instance with policy-name derived from prefix" do
      instance = Gcp.map_routes(@routes, @config)
      assert instance["gcp-armor-config"]["policy-name"] == "myapp-security-policy"
    end

    test "rules list contains deny(403) rule at priority 1000" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      deny = Enum.find(rules, &(&1["priority"] == 1000))
      assert deny != nil
      assert deny["action"] == "deny(403)"
    end

    test "deny rule CEL expression uses request.path for all routes" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      deny = Enum.find(rules, &(&1["priority"] == 1000))
      expr = deny["cel-expression"]
      assert expr =~ "request.path"
      assert expr =~ "!request.path.matches"
    end

    test "deny rule CEL expression combines all paths with &&" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      deny = Enum.find(rules, &(&1["priority"] == 1000))
      expr = deny["cel-expression"]
      # Should have negated match for each route
      assert expr =~ "!request.path.matches('^/api/users$')"
      assert expr =~ "!request.path.matches('^/health$')"
      assert String.contains?(expr, "&&")
    end

    test "rate-limited route generates rate_based_ban rule" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rule = Enum.find(rules, &(&1["action"] == "rate_based_ban"))
      assert rate_rule != nil
      assert rate_rule["match-type"] == "expr"
      assert rate_rule["cel-expression"] =~ "request.path.matches"
    end

    test "rate_based_ban rule has correct rate-limit-options" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rule = Enum.find(rules, &(&1["action"] == "rate_based_ban"))
      rl = rate_rule["rate-limit-options"]
      assert rl["conform-action"] == "allow"
      assert rl["exceed-action"] == "deny(429)"
      assert rl["rate-limit-count"] == 100
      assert rl["rate-limit-interval-sec"] == 60
    end

    test "rate limit count is NOT multiplied (uses raw value)" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rule = Enum.find(rules, &(&1["action"] == "rate_based_ban"))
      assert rate_rule["rate-limit-options"]["rate-limit-count"] == 100
    end

    test "routes without rate limit do not generate rate_based_ban rules" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = Gcp.map_routes(routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rules = Enum.filter(rules, &(&1["action"] == "rate_based_ban"))
      assert rate_rules == []
    end

    test "default allow rule exists at priority 2147483647" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default != nil
      assert default["action"] == "allow"
      assert default["match-type"] == "versioned-expr"
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "produces valid JSON" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      assert {:ok, _decoded} = Jason.decode(output)
    end

    test "output has name and rules array" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      assert decoded["name"] == "myapp-security-policy"
      assert is_list(decoded["rules"])
    end

    test "output contains request.path.matches in deny rule" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      assert output =~ "request.path.matches"
    end

    test "deny(403) rule is present in output" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      assert output =~ "deny(403)"
    end

    test "rate_based_ban rule has rateLimitOptions in output" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      rate_rule = Enum.find(decoded["rules"], &(&1["action"] == "rate_based_ban"))
      assert rate_rule != nil
      rl = rate_rule["rateLimitOptions"]
      assert rl["conformAction"] == "allow"
      assert rl["exceedAction"] == "deny(429)"
      assert rl["rateLimitThreshold"]["count"] == 100
      assert rl["rateLimitThreshold"]["intervalSec"] == 60
    end

    test "default allow rule uses SRC_IPS_V1 versioned expression" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      default = Enum.find(decoded["rules"], &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "allow"
      assert default["match"]["versionedExpr"] == "SRC_IPS_V1"
      assert default["match"]["config"]["srcIpRanges"] == ["*"]
    end

    test "rules array is non-empty and has at least deny and default rules" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      assert length(decoded["rules"]) >= 2
    end
  end
end
