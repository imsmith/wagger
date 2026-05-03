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

    test "allow rules exist at priority 2000+ and use a single matches() per rule" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))
      assert length(allow_rules) >= 1

      for rule <- allow_rules do
        assert rule["action"] == "allow"
        assert rule["match-type"] == "expr"
        # Exactly one `request.path.matches(...)` call per rule; multiple
        # paths are alternation inside the regex (not multiple matches()
        # calls joined by `||`). Cloud Armor caps sub-expressions at 5.
        matches_count =
          rule["cel-expression"]
          |> String.split("request.path.matches")
          |> length()
          |> Kernel.-(1)

        assert matches_count == 1,
               "expected exactly one matches() call per rule; got #{matches_count}"
      end
    end

    test "allow rules collectively cover every route's regex" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))
      combined = allow_rules |> Enum.map(& &1["cel-expression"]) |> Enum.join("\n")
      assert combined =~ "^/api/users$"
      assert combined =~ "^/api/users/[^/]+$"
      assert combined =~ "^/health$"
    end

    test "allow rule expressions stay under Cloud Armor's per-rule limits" do
      # Cloud Armor enforces:
      #   - 2048 chars per CEL expression
      #   - 1024 chars per inner regex (string inside matches())
      #   - 5 sub-expressions per rule (operands of || or &&)
      # Generate a synthetic large route set to exercise chunking.
      big_routes =
        for i <- 1..200 do
          %{
            path: "/api/endpoint_with_a_reasonably_long_name_#{i}",
            methods: ["GET"],
            path_type: "exact",
            rate_limit: nil
          }
        end

      instance = Gcp.map_routes(big_routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      assert length(allow_rules) > 1, "200 routes should produce multiple chunked allow rules"

      for rule <- allow_rules do
        expr = rule["cel-expression"]

        assert String.length(expr) <= 2048,
               "allow rule expression exceeds Cloud Armor 2048-char limit: #{String.length(expr)}"

        inner_regex =
          case Regex.run(~r/request\.path\.matches\('([^']*)'\)/, expr) do
            [_, regex] -> regex
            nil -> ""
          end

        assert String.length(inner_regex) <= 1024,
               "inner regex exceeds Cloud Armor 1024-char limit: #{String.length(inner_regex)}"

        # Sub-expression count = boolean operands of || or &&. Inside a
        # single regex string, `|` is regex alternation, not a CEL operator.
        # We use one matches() per rule, which is exactly one sub-expression.
        cel_or_count =
          expr
          |> String.split(" || ")
          |> length()
          |> Kernel.-(1)

        cel_and_count =
          expr
          |> String.split(" && ")
          |> length()
          |> Kernel.-(1)

        sub_expr_count = cel_or_count + cel_and_count + 1
        assert sub_expr_count <= 5,
               "rule has #{sub_expr_count} sub-expressions; Cloud Armor limit is 5"
      end
    end

    test "deny-all rule exists at priority 3000 with action deny(403)" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      deny = Enum.find(rules, &(&1["priority"] == 3000))
      assert deny != nil
      assert deny["action"] == "deny(403)"
      assert deny["match-type"] == "versioned-expr"
    end

    test "default rule exists at priority 2147483647 (Cloud Armor convention)" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      default = Enum.find(rules, &(&1["priority"] == 2_147_483_647))
      assert default != nil
      assert default["action"] == "allow"
      assert default["match-type"] == "versioned-expr"
    end

    test "rule priority order: rate (1000+) < allow (2000+) < deny-all (3000) < default" do
      instance = Gcp.map_routes(@routes, @config)
      priorities = Enum.map(instance["gcp-armor-config"]["rules"], & &1["priority"])
      assert Enum.sort(priorities) == priorities, "rules should be emitted in priority order"
    end
  end

  # ---------------------------------------------------------------------------
  # Method enforcement (allow rules must check (method, path), not path alone)
  # ---------------------------------------------------------------------------

  describe "method enforcement on allow rules" do
    test "every allow rule references request.method" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      for rule <- allow_rules do
        assert rule["cel-expression"] =~ "request.method",
               "allow rule does not check method: #{rule["cel-expression"]}"
      end
    end

    test "routes with distinct method-sets emit distinct allow rules" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = Gcp.map_routes(routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      assert length(allow_rules) >= 2,
             "expected at least 2 allow rules for distinct method-sets, got #{length(allow_rules)}"

      # Each allow rule should reference exactly one method-set
      get_rule = Enum.find(allow_rules, &(&1["cel-expression"] =~ "/a"))
      post_rule = Enum.find(allow_rules, &(&1["cel-expression"] =~ "/b"))

      assert get_rule["cel-expression"] =~ "'GET'"
      refute get_rule["cel-expression"] =~ "'POST'"
      assert post_rule["cel-expression"] =~ "'POST'"
      refute post_rule["cel-expression"] =~ "'GET'"
    end

    test "routes sharing a method-set are packed in the same allow rule" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/c", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      instance = Gcp.map_routes(routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      # Three GET-only routes should fit in one rule
      assert length(allow_rules) == 1
      expr = hd(allow_rules)["cel-expression"]
      assert expr =~ "/a"
      assert expr =~ "/b"
      assert expr =~ "/c"
    end

    test "atomic explosion: [GET,POST] /a equivalent to [GET] /a + [POST] /a" do
      multi = [
        %{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}
      ]

      atomic = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/a", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      multi_rules =
        Gcp.map_routes(multi, @config)["gcp-armor-config"]["rules"]
        |> Enum.filter(&(&1["priority"] >= 2000 and &1["priority"] < 3000))
        |> Enum.map(& &1["cel-expression"])
        |> Enum.sort()

      atomic_rules =
        Gcp.map_routes(atomic, @config)["gcp-armor-config"]["rules"]
        |> Enum.filter(&(&1["priority"] >= 2000 and &1["priority"] < 3000))
        |> Enum.map(& &1["cel-expression"])
        |> Enum.sort()

      assert multi_rules == atomic_rules
    end

    test "method check + matches() stays within 5 sub-expression limit" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      for rule <- allow_rules do
        expr = rule["cel-expression"]

        cel_or = expr |> String.split(" || ") |> length() |> Kernel.-(1)
        cel_and = expr |> String.split(" && ") |> length() |> Kernel.-(1)
        sub_expr_count = cel_or + cel_and + 1

        assert sub_expr_count <= 5,
               "rule has #{sub_expr_count} sub-expressions; Cloud Armor limit is 5"
      end
    end

    test "method-set with multiple methods uses 'in' list" do
      routes = [
        %{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = Gcp.map_routes(routes, @config)
      rules = instance["gcp-armor-config"]["rules"]
      allow_rules = Enum.filter(rules, &(&1["priority"] >= 2000 and &1["priority"] < 3000))

      expr = hd(allow_rules)["cel-expression"]
      assert expr =~ "request.method in"
      assert expr =~ "'GET'"
      assert expr =~ "'POST'"
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

    test "output contains request.path.matches in allow rules" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      assert output =~ "request.path.matches"
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

    test "default rule uses SRC_IPS_V1 versioned expression" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      default = Enum.find(decoded["rules"], &(&1["priority"] == 2_147_483_647))
      assert default["action"] == "allow"
      assert default["match"]["versionedExpr"] == "SRC_IPS_V1"
      assert default["match"]["config"]["srcIpRanges"] == ["*"]
    end

    test "deny-all rule at priority 3000 uses SRC_IPS_V1 with srcIpRanges *" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      deny = Enum.find(decoded["rules"], &(&1["priority"] == 3000))
      assert deny["action"] == "deny(403)"
      assert deny["match"]["versionedExpr"] == "SRC_IPS_V1"
      assert deny["match"]["config"]["srcIpRanges"] == ["*"]
    end
  end
end
