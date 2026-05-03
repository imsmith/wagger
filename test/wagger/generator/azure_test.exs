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
  # Method enforcement (block disallowed methods on allowed paths)
  #
  # Azure custom rules' matchConditions AND together within a rule, so the
  # negated path-allowlist alone can't express "block if (method, path)
  # not in allowlist" when more than one method-set exists. The fix layers
  # additional Block rules on top of the existing path-allowlist: one per
  # method-set bucket, firing when "URI matches bucket-paths AND method
  # NOT in bucket-methods."
  # ---------------------------------------------------------------------------

  describe "method enforcement on allowed paths" do
    test "emits a method-enforcement Block rule per distinct method-set" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = Azure.map_routes(routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]

      method_rules = Enum.filter(rules, &String.contains?(&1["name"], "EnforceMethods"))
      assert length(method_rules) == 2
    end

    test "method enforcement rule has two match conditions: URI match + method NOT in set" do
      routes = [%{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}]
      instance = Azure.map_routes(routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]

      method_rule = Enum.find(rules, &String.contains?(&1["name"], "EnforceMethods"))
      assert method_rule != nil
      assert method_rule["action"] == "Block"

      conditions = method_rule["match-conditions"]
      assert length(conditions) == 2

      uri_cond = Enum.find(conditions, &(&1["match-variable"] == "RequestUri"))
      assert uri_cond["negate-condition"] == false
      assert "^/a$" in uri_cond["match-values"]

      method_cond = Enum.find(conditions, &(&1["match-variable"] == "RequestMethod"))
      assert method_cond["negate-condition"] == true
      assert Enum.sort(method_cond["match-values"]) == ["GET", "POST"]
    end

    test "single-method bucket lists only that method in negated condition" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = Azure.map_routes(routes, @config)
      rules = instance["azure-fd-policy"]["custom-rules"]["rules"]

      method_rule = Enum.find(rules, &String.contains?(&1["name"], "EnforceMethods"))
      method_cond =
        Enum.find(method_rule["match-conditions"], &(&1["match-variable"] == "RequestMethod"))

      assert method_cond["match-values"] == ["GET"]
      assert method_cond["negate-condition"] == true
    end

    test "routes sharing a method-set are packed in one method-enforcement rule" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/c", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      instance = Azure.map_routes(routes, @config)
      method_rules =
        instance["azure-fd-policy"]["custom-rules"]["rules"]
        |> Enum.filter(&String.contains?(&1["name"], "EnforceMethods"))

      assert length(method_rules) == 1

      uri_cond =
        hd(method_rules)["match-conditions"]
        |> Enum.find(&(&1["match-variable"] == "RequestUri"))

      assert "^/a$" in uri_cond["match-values"]
      assert "^/b$" in uri_cond["match-values"]
      assert "^/c$" in uri_cond["match-values"]
    end

    test "atomic explosion: [GET,POST] /a equivalent to [GET] /a + [POST] /a" do
      multi = [%{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}]

      atomic = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/a", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      multi_method_rules =
        Azure.map_routes(multi, @config)["azure-fd-policy"]["custom-rules"]["rules"]
        |> Enum.filter(&String.contains?(&1["name"], "EnforceMethods"))
        |> Enum.map(&(&1["match-conditions"]))

      atomic_method_rules =
        Azure.map_routes(atomic, @config)["azure-fd-policy"]["custom-rules"]["rules"]
        |> Enum.filter(&String.contains?(&1["name"], "EnforceMethods"))
        |> Enum.map(&(&1["match-conditions"]))

      assert multi_method_rules == atomic_method_rules
    end

    test "method-enforcement rules have priority between allowlist (1) and rate-limit (100)" do
      instance = Azure.map_routes(@routes, @config)
      method_rules =
        instance["azure-fd-policy"]["custom-rules"]["rules"]
        |> Enum.filter(&String.contains?(&1["name"], "EnforceMethods"))

      for rule <- method_rules do
        assert rule["priority"] > 1 and rule["priority"] < 100,
               "method-enforcement priority #{rule["priority"]} out of expected range"
      end
    end

    test "method-enforcement rule serialized with correct Azure shape" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      rules = get_in(decoded, ["properties", "customRules", "rules"])

      method_rule = Enum.find(rules, &String.contains?(&1["name"], "EnforceMethods"))
      assert method_rule != nil
      assert method_rule["action"] == "Block"

      method_cond =
        Enum.find(method_rule["matchConditions"], &(&1["matchVariable"] == "RequestMethod"))

      assert method_cond["negateCondition"] == true
      assert is_list(method_cond["matchValue"])
      assert "GET" in method_cond["matchValue"] or
               Enum.any?(method_cond["matchValue"], &(&1 in ["GET", "POST", "PUT", "DELETE"]))
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
