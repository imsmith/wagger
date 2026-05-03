defmodule Wagger.Generator.CloudflareTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Cloudflare

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
    test "produces a block rule with not (...) expression" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block_rule = Enum.find(rules, &(&1["action"] == "block"))

      assert block_rule != nil
      assert String.starts_with?(block_rule["expression"], "not (")
      assert String.ends_with?(block_rule["expression"], ")")
    end

    test "uses eq for exact paths without params" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block_rule = Enum.find(rules, &(&1["action"] == "block"))

      assert block_rule["expression"] =~ ~s|http.request.uri.path eq "/api/users"|
      assert block_rule["expression"] =~ ~s|http.request.uri.path eq "/health"|
    end

    test "uses starts_with for prefix paths" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block_rule = Enum.find(rules, &(&1["action"] == "block"))

      assert block_rule["expression"] =~ ~s|starts_with(http.request.uri.path, "/static/")|
    end

    test "uses matches for paths with params" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block_rule = Enum.find(rules, &(&1["action"] == "block"))

      assert block_rule["expression"] =~ ~s|http.request.uri.path matches "^/api/users/[^/]+$"|
    end

    test "creates managed_challenge rule with ratelimit for rate-limited routes" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      rl_rule = Enum.find(rules, &(&1["action"] == "managed_challenge"))

      assert rl_rule != nil
      assert rl_rule["description"] =~ "/api/users"

      rl = rl_rule["ratelimit"]
      assert rl["period"] == 60
      assert rl["requests_per_period"] == 100
      assert rl["mitigation_timeout"] == 600
      assert rl["characteristics"] == ["ip.src"]
    end

    test "no managed_challenge rule for routes without rate_limit" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      rl_rules = Enum.filter(rules, &(&1["action"] == "managed_challenge"))

      # Only /api/users has rate_limit set
      assert length(rl_rules) == 1
    end

    test "config-name matches prefix" do
      instance = Cloudflare.map_routes(@routes, @config)
      assert instance["cloudflare-config"]["config-name"] == "myapp"
    end

    test "block rule description includes prefix" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block_rule = Enum.find(rules, &(&1["action"] == "block"))
      assert block_rule["description"] =~ "myapp"
    end

    test "all rules have enabled: true" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      assert Enum.all?(rules, &(&1["enabled"] == true))
    end
  end

  # ---------------------------------------------------------------------------
  # Method enforcement (allow rule must check (method, path), not path alone)
  # ---------------------------------------------------------------------------

  describe "method enforcement on block rule" do
    test "block expression references http.request.method" do
      instance = Cloudflare.map_routes(@routes, @config)
      block_rule =
        instance["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))

      assert block_rule["expression"] =~ "http.request.method"
    end

    test "single-method route uses eq for method check" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = Cloudflare.map_routes(routes, @config)
      block_rule =
        instance["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))

      assert block_rule["expression"] =~ ~s|http.request.method eq "GET"|
    end

    test "multi-method route uses in {...} set syntax" do
      routes = [
        %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = Cloudflare.map_routes(routes, @config)
      block_rule =
        instance["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))

      assert block_rule["expression"] =~ ~s|http.request.method in {"GET" "POST"}|
    end

    test "routes with distinct method-sets become distinct OR-clauses, not interleaved" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = Cloudflare.map_routes(routes, @config)
      expr =
        instance["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))
        |> Map.get("expression")

      # Each path should be paired ONLY with its own method, not the other's
      get_clause_position = position_of(expr, "/a")
      post_clause_position = position_of(expr, "/b")

      get_method_position = position_of(expr, ~s|"GET"|)
      post_method_position = position_of(expr, ~s|"POST"|)

      # Method tokens must actually appear (>= 0) and precede their paired path
      assert get_method_position >= 0, "GET method check missing from expression"
      assert post_method_position >= 0, "POST method check missing from expression"
      assert get_method_position < get_clause_position
      assert post_method_position < post_clause_position
    end

    test "routes sharing a method-set are packed under one method check" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/c", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      instance = Cloudflare.map_routes(routes, @config)
      expr =
        instance["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))
        |> Map.get("expression")

      # Only one method check should appear; paths share it
      method_check_count =
        expr
        |> String.split("http.request.method")
        |> length()
        |> Kernel.-(1)

      assert method_check_count == 1,
             "expected one method check for shared-bucket paths, got #{method_check_count}"
    end

    test "atomic explosion: [GET,POST] /a equivalent to [GET] /a + [POST] /a" do
      multi = [%{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}]

      atomic = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/a", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      multi_expr =
        Cloudflare.map_routes(multi, @config)["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))
        |> Map.get("expression")

      atomic_expr =
        Cloudflare.map_routes(atomic, @config)["cloudflare-config"]["rules"]
        |> Enum.find(&(&1["action"] == "block"))
        |> Map.get("expression")

      assert multi_expr == atomic_expr
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "generates valid JSON array" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      assert {:ok, parsed} = Jason.decode(extract_json(output))
      assert is_list(parsed)
    end

    test "JSON output contains block rule" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      assert {:ok, rules} = Jason.decode(extract_json(output))
      block_rule = Enum.find(rules, &(&1["action"] == "block"))
      assert block_rule != nil
    end

    test "JSON output block rule uses not (...) expression" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      assert output =~ "not ("
    end

    test "JSON output contains managed_challenge rule with ratelimit" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      assert {:ok, rules} = Jason.decode(extract_json(output))
      rl_rule = Enum.find(rules, &(&1["action"] == "managed_challenge"))

      assert rl_rule != nil
      assert rl_rule["ratelimit"]["period"] == 60
      assert rl_rule["ratelimit"]["requests_per_period"] == 100
      assert rl_rule["ratelimit"]["mitigation_timeout"] == 600
    end

    test "JSON output uses correct expression types for each path" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      assert {:ok, rules} = Jason.decode(extract_json(output))
      block_rule = Enum.find(rules, &(&1["action"] == "block"))
      expr = block_rule["expression"]

      # eq for exact without params
      assert expr =~ ~s|http.request.uri.path eq "/api/users"|
      # matches for exact with params
      assert expr =~ ~s|http.request.uri.path matches|
      # starts_with for prefix
      assert expr =~ ~s|starts_with(http.request.uri.path|
    end

    test "YANG model parses and resolves" do
      yang_source = Cloudflare.yang_module()
      assert {:ok, parsed} = ExYang.parse(yang_source)
      assert {:ok, _resolved} = ExYang.resolve(parsed, %{})
    end
  end

  defp position_of(string, needle) do
    case :binary.match(string, needle) do
      {pos, _} -> pos
      :nomatch -> -1
    end
  end

  # Strip comment block to get at the JSON
  defp extract_json(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
    |> String.trim()
  end
end
