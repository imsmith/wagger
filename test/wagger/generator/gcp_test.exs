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

    test "rate-limited route generates rate_based_ban rule at priority 1000+" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rule = Enum.find(rules, &(&1["action"] == "rate_based_ban"))
      assert rate_rule != nil
      assert rate_rule["priority"] >= 1000 and rate_rule["priority"] < 2000
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

    test "routes without rate limit do not generate rate_based_ban rules" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = Gcp.map_routes(routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      rate_rules = Enum.filter(rules, &(&1["action"] == "rate_based_ban"))
      assert rate_rules == []
    end

    test "default rule is deny(403) — (method, path) gating delegated to URL Map" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default != nil
      assert default["action"] == "deny(403)"
      assert default["description"] =~ "URL Map"
      assert default["match-type"] == "versioned-expr"
    end

    test "rule priority order: rate (1000+) < posture-allow (2000) < default (max)" do
      instance = Gcp.map_routes(@routes, @config)
      priorities = Enum.map(instance["gcp-armor-config"]["rules"], & &1["priority"])
      assert Enum.sort(priorities) == priorities, "rules should be emitted in priority order"
    end

    test "no per-route allow rules with request.path.matches — that is URL Map's job" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]

      per_route_allow =
        Enum.filter(rules, fn rule ->
          rule["action"] == "allow" and
            is_binary(rule["cel-expression"]) and
            rule["cel-expression"] =~ "request.path.matches"
        end)

      assert per_route_allow == [],
             "Cloud Armor must not emit per-route path-matching allow rules"
    end
  end

  # ---------------------------------------------------------------------------
  # Posture allow rules
  # ---------------------------------------------------------------------------

  describe "posture allow rules" do
    test "no declared posture emits one permissive allow at priority 2000" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture != nil
      assert posture["action"] == "allow"
      assert posture["description"] =~ "Permissive allow"
      assert posture["description"] =~ "defense-in-depth"
      assert posture["match-type"] == "versioned-expr"
    end

    test "no declared posture — default rule is deny(403)" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "deny(403)"
    end

    test "IP allowlist only — allow rule references declared CIDRs, default deny(403)" do
      config = Map.put(@config, :allow_ip_ranges, ["10.0.0.0/8", "192.168.0.0/16"])
      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]

      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture["action"] == "allow"
      assert posture["match-type"] == "versioned-expr"
      assert posture["src-ip-ranges"] == ["10.0.0.0/8", "192.168.0.0/16"]

      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "deny(403)"
    end

    test "geo allowlist only — allow rule uses origin.region_code CEL, default deny(403)" do
      config = Map.put(@config, :allow_regions, ["US", "GB"])
      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]

      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture["action"] == "allow"
      assert posture["match-type"] == "expr"
      assert posture["cel-expression"] =~ "origin.region_code"
      assert posture["cel-expression"] =~ "'US'"
      assert posture["cel-expression"] =~ "'GB'"

      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "deny(403)"
    end

    test "both IP and geo — combined CEL rule ANDs both checks, default deny(403)" do
      config =
        @config
        |> Map.put(:allow_ip_ranges, ["10.0.0.0/8"])
        |> Map.put(:allow_regions, ["US"])

      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]

      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture["action"] == "allow"
      assert posture["match-type"] == "expr"
      expr = posture["cel-expression"]
      assert expr =~ "origin.region_code"
      assert expr =~ "inIpRange"
      assert expr =~ "&&"

      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "deny(403)"
    end

    test "string-keyed config works for allow_ip_ranges" do
      config = %{"prefix" => "test", "allow_ip_ranges" => ["10.0.0.0/8"]}
      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]
      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture["src-ip-ranges"] == ["10.0.0.0/8"]
    end

    test "string-keyed config works for allow_regions" do
      config = %{"prefix" => "test", "allow_regions" => ["CA"]}
      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]
      posture = Enum.find(rules, &(&1["priority"] == 2000))
      assert posture["cel-expression"] =~ "'CA'"
    end

    test "regression: non-empty route list does NOT produce per-route path-matching allow rules" do
      config = Map.put(@config, :allow_ip_ranges, ["10.0.0.0/8"])
      instance = Gcp.map_routes(@routes, config)
      rules = instance["gcp-armor-config"]["rules"]

      per_route_path_rules =
        Enum.filter(rules, fn rule ->
          rule["action"] == "allow" and
            is_binary(rule["cel-expression"]) and
            rule["cel-expression"] =~ "request.path.matches"
        end)

      assert per_route_path_rules == [],
             "expected no per-route path-matching allow rules from Cloud Armor"
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

    test "deny(403) appears in output" do
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

    test "default rule uses SRC_IPS_V1 versioned expression with deny(403)" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      default = Enum.find(decoded["rules"], &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "deny(403)"
      assert default["match"]["versionedExpr"] == "SRC_IPS_V1"
      assert default["match"]["config"]["srcIpRanges"] == ["*"]
    end

    test "posture allow rule uses SRC_IPS_V1 with srcIpRanges [*] when no posture declared" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      posture = Enum.find(decoded["rules"], &(&1["priority"] == 2000))
      assert posture["action"] == "allow"
      assert posture["match"]["versionedExpr"] == "SRC_IPS_V1"
      assert posture["match"]["config"]["srcIpRanges"] == ["*"]
    end

    test "IP posture: serialised rule uses declared srcIpRanges" do
      config = Map.put(@config, :allow_ip_ranges, ["10.0.0.0/8"])
      assert {:ok, output} = Generator.generate(Gcp, @routes, config)
      decoded = Jason.decode!(output)
      posture = Enum.find(decoded["rules"], &(&1["priority"] == 2000))
      assert posture["match"]["config"]["srcIpRanges"] == ["10.0.0.0/8"]
    end

    test "geo posture: serialised rule uses expr match with region CEL" do
      config = Map.put(@config, :allow_regions, ["US"])
      assert {:ok, output} = Generator.generate(Gcp, @routes, config)
      decoded = Jason.decode!(output)
      posture = Enum.find(decoded["rules"], &(&1["priority"] == 2000))
      assert posture["match"]["expr"]["expression"] =~ "origin.region_code"
    end
  end
end
