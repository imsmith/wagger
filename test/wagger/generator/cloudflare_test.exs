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

  # Strip comment block to get at the JSON
  defp extract_json(output) do
    output
    |> String.split("\n")
    |> Enum.drop_while(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
    |> String.trim()
  end
end
