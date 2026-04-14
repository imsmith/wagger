defmodule Wagger.Generator.AzureTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Azure

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]

  @config %{prefix: "myapp", mode: "Prevention"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "creates allowlist rule with negated condition and 4 match patterns" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "MatchRule"))

      assert allowlist != nil
      condition = hd(allowlist["match-conditions"])
      assert condition["negate-condition"] == true
      assert condition["operator"] == "RegEx"

      patterns = condition["match-values"]
      assert length(patterns) == 4
      assert "^/api/users$" in patterns
      assert "^/api/users/[^/]+$" in patterns
      assert "^/static/.*" in patterns
      assert "^/health$" in patterns
    end

    test "multiplies rate limit by 5 (threshold: 500, duration: 5 minutes)" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]
      rate_rule = Enum.find(rules, &(&1["rule-type"] == "RateLimitRule"))

      assert rate_rule != nil
      assert rate_rule["rate-limit-threshold"] == 500
      assert rate_rule["rate-limit-duration-in-minutes"] == 5
    end

    test "allowlist rule action is Block" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "MatchRule"))
      assert allowlist["action"] == "Block"
    end

    test "allowlist rule has priority 1" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "MatchRule"))
      assert allowlist["priority"] == 1
    end

    test "policy mode is taken from config" do
      instance = Azure.map_routes(@routes, @config)
      assert instance["azure-fd-policy"]["mode"] == "Prevention"
    end

    test "policy name matches prefix" do
      instance = Azure.map_routes(@routes, @config)
      assert instance["azure-fd-policy"]["policy-name"] == "myapp"
    end

    test "only routes with rate_limit produce RateLimitRule entries" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]
      rate_rules = Enum.filter(rules, &(&1["rule-type"] == "RateLimitRule"))
      # Only /api/users has a rate_limit
      assert length(rate_rules) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "produces valid JSON with properties.policySettings.mode" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      assert get_in(decoded, ["properties", "policySettings", "mode"]) == "Prevention"
    end

    test "output includes UrlDecode and Lowercase transforms" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      assert output =~ "UrlDecode"
      assert output =~ "Lowercase"
    end

    test "allowlist rule appears in serialized output with negateCondition true" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      rules = get_in(decoded, ["properties", "customRules", "rules"])
      allowlist = Enum.find(rules, &(&1["ruleType"] == "MatchRule"))
      condition = hd(allowlist["matchConditions"])
      assert condition["negateCondition"] == true
      assert length(condition["matchValue"]) == 4
    end

    test "rate limit rule appears with correct threshold and duration" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      rules = get_in(decoded, ["properties", "customRules", "rules"])
      rate_rule = Enum.find(rules, &(&1["ruleType"] == "RateLimitRule"))
      assert rate_rule["rateLimitThreshold"] == 500
      assert rate_rule["rateLimitDurationInMinutes"] == 5
    end

    test "policySettings enabledState is Enabled" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      assert get_in(decoded, ["properties", "policySettings", "enabledState"]) == "Enabled"
    end

    test "Detection mode is preserved in output" do
      assert {:ok, output} = Generator.generate(Azure, @routes, %{prefix: "myapp", mode: "Detection"})
      decoded = Jason.decode!(output)
      assert get_in(decoded, ["properties", "policySettings", "mode"]) == "Detection"
    end
  end
end
