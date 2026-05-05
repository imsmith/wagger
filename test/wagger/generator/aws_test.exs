defmodule Wagger.Generator.AwsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Aws

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]

  @config %{prefix: "myapp", scope: "REGIONAL"}

  # ---------------------------------------------------------------------------
  # map_routes/2 unit tests
  # ---------------------------------------------------------------------------

  describe "map_routes/2" do
    test "produces instance with web-acl name derived from prefix" do
      instance = Aws.map_routes(@routes, @config)
      assert instance["aws-waf-config"]["web-acl-name"] == "myapp-web-acl"
    end

    test "produces instance with correct scope" do
      instance = Aws.map_routes(@routes, @config)
      assert instance["aws-waf-config"]["scope"] == "REGIONAL"
    end

    test "path-allowlist rule has correct number of patterns" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      allowlist = Enum.find(rules, &(&1["name"] =~ "path-allowlist"))
      patterns = allowlist["path-patterns"]
      assert length(patterns) == length(@routes)
    end

    test "exact path without params uses EXACTLY match type" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      allowlist = Enum.find(rules, &(&1["name"] =~ "path-allowlist"))
      patterns = allowlist["path-patterns"]
      health = Enum.find(patterns, &(&1["path"] == "/health"))
      assert health["match-type"] == "EXACTLY"
    end

    test "prefix path uses STARTS_WITH match type" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      allowlist = Enum.find(rules, &(&1["name"] =~ "path-allowlist"))
      patterns = allowlist["path-patterns"]
      static = Enum.find(patterns, &(&1["path"] == "/static/"))
      assert static["match-type"] == "STARTS_WITH"
    end

    test "path with params uses REGEX match type (not CONTAINS)" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      allowlist = Enum.find(rules, &(&1["name"] =~ "path-allowlist"))
      patterns = allowlist["path-patterns"]
      user_detail = Enum.find(patterns, &(&1["match-type"] == "REGEX"))
      assert user_detail != nil
      refute Enum.any?(patterns, &(&1["match-type"] == "CONTAINS"))
    end

    test "rate limit is multiplied by 5" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      rate_rule = Enum.find(rules, &(&1["name"] =~ "rate-limit"))
      assert rate_rule != nil
      # 100 req/min * 5 = 500 per AWS 5-minute window
      assert rate_rule["rate-limit"] == 500
    end

    test "routes without rate limit do not generate rate-limit rules" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = Aws.map_routes(routes, @config)
      rules = instance["aws-waf-config"]["rules"]
      rate_rules = Enum.filter(rules, &(&1["name"] =~ "rate-limit"))
      assert rate_rules == []
    end
  end

  # ---------------------------------------------------------------------------
  # Full pipeline tests via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "produces valid JSON" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert {:ok, _decoded} = Jason.decode(output)
    end

    test "output includes web ACL name and scope" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "myapp-web-acl"
      assert output =~ "REGIONAL"
    end

    test "output includes DefaultAction Allow" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)
      assert decoded["DefaultAction"] == %{"Allow" => %{}}
    end

    test "output includes URL_DECODE and LOWERCASE transforms" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "URL_DECODE"
      assert output =~ "LOWERCASE"
    end

    test "output includes RateBasedStatement for rate-limited routes" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "RateBasedStatement"
    end

    test "output uses NotStatement wrapping OrStatement for path allowlist" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "NotStatement"
      assert output =~ "OrStatement"
    end

    test "output uses RegexMatchStatement for paths with params, not ByteMatchStatement with CONTAINS" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "RegexMatchStatement"
      # Should not use CONTAINS — that is the prior implementation bug
      refute output =~ ~s("CONTAINS")
    end

    test "output includes ByteMatchStatement with EXACTLY for exact paths without params" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "ByteMatchStatement"
      assert output =~ "EXACTLY"
    end

    test "ByteMatchStatement.SearchString is base64-encoded (AWS Blob type)" do
      # AWS WAF API documents ByteMatchStatement.SearchString as a Blob; over the
      # JSON wire format it must be base64-encoded. Emitting raw text forces
      # callers to pass --cli-binary-format raw-in-base64-out, which is a leaky
      # workaround. Verify all SearchString values decode back to expected literals.
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)

      search_strings =
        decoded["Rules"]
        |> Enum.flat_map(&collect_search_strings/1)

      assert search_strings != []

      Enum.each(search_strings, fn s ->
        assert is_binary(s)
        assert {:ok, _decoded} = Base.decode64(s),
               "expected base64-encoded SearchString, got #{inspect(s)}"
      end)

      decoded_values = Enum.map(search_strings, &Base.decode64!/1)

      # Method enforcement strings round-trip to lowercase HTTP method
      # literals. The standard transforms include LOWERCASE, so the
      # stored SearchString must already be lowercase to match a
      # transformed request method.
      assert "get" in decoded_values
      assert "post" in decoded_values
      refute "GET" in decoded_values
      refute "POST" in decoded_values

      # Path allowlist strings should round-trip to declared paths.
      assert "/health" in decoded_values
      assert "/api/users" in decoded_values
    end

    test "method-enforcement rules are scoped by path (AndStatement with path predicate)" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)

      method_rules =
        Enum.filter(decoded["Rules"], fn r -> r["Name"] =~ "methods-group-" end)

      assert method_rules != [], "expected at least one method-enforcement rule"

      Enum.each(method_rules, fn rule ->
        assert %{"AndStatement" => %{"Statements" => [path_stmt, not_stmt]}} =
                 rule["Statement"],
               "method-enforcement rule #{rule["Name"]} must wrap its predicates in AndStatement"

        # The path side is either a single path matcher or an OrStatement
        # of path matchers; in both cases the leaf must be a UriPath
        # ByteMatchStatement or a UriPath RegexMatchStatement.
        path_leaves = collect_path_leaves(path_stmt)
        assert path_leaves != [], "rule #{rule["Name"]} has no path predicate"

        Enum.each(path_leaves, fn leaf ->
          assert leaf == :byte_uripath or leaf == :regex_uripath,
                 "expected path predicate to match UriPath, got #{inspect(leaf)}"
        end)

        # The other side is a NotStatement around the method matchers.
        assert %{"NotStatement" => _} = not_stmt
      end)
    end

    test "method-enforcement rule for the GET-only group is path-scoped to its routes" do
      # /static/ (prefix) and /health (exact) are the only GET-only routes;
      # they must show up under the methods-group-get rule's path predicate
      # and nowhere else.
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)

      get_rule =
        Enum.find(decoded["Rules"], fn r ->
          r["Name"] == "myapp-methods-group-get"
        end)

      assert get_rule != nil, "expected myapp-methods-group-get rule"

      [path_stmt, _not_stmt] = get_rule["Statement"]["AndStatement"]["Statements"]
      paths = collect_search_paths(path_stmt) |> MapSet.new()

      assert MapSet.member?(paths, "/health")
      # /static/ is a prefix path → STARTS_WITH match → SearchString is the
      # raw prefix string (base64-encoded as a Blob).
      assert MapSet.member?(paths, "/static/")
    end

    test "output includes VisibilityConfig" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)
      assert Map.has_key?(decoded, "VisibilityConfig")
    end

    test "Rules list is non-empty" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)
      assert is_list(decoded["Rules"])
      assert length(decoded["Rules"]) > 0
    end
  end

  defp collect_search_strings(%{"SearchString" => s} = node) do
    [s | node |> Map.delete("SearchString") |> collect_search_strings()]
  end

  defp collect_search_strings(map) when is_map(map) do
    Enum.flat_map(map, fn {_k, v} -> collect_search_strings(v) end)
  end

  defp collect_search_strings(list) when is_list(list) do
    Enum.flat_map(list, &collect_search_strings/1)
  end

  defp collect_search_strings(_), do: []

  # Walks a path-side statement and returns a list of leaf-kind tags so we
  # can assert every leaf actually targets UriPath. Returns :byte_uripath
  # for a UriPath ByteMatchStatement, :regex_uripath for a RegexMatchStatement.
  defp collect_path_leaves(%{"OrStatement" => %{"Statements" => stmts}}),
    do: Enum.flat_map(stmts, &collect_path_leaves/1)

  defp collect_path_leaves(%{"ByteMatchStatement" => %{"FieldToMatch" => %{"UriPath" => _}}}),
    do: [:byte_uripath]

  defp collect_path_leaves(%{"RegexMatchStatement" => %{"FieldToMatch" => %{"UriPath" => _}}}),
    do: [:regex_uripath]

  defp collect_path_leaves(_), do: []

  # Walks a path-side statement and returns the decoded literal SearchString
  # values for ByteMatchStatement leaves (paths only — not regexes).
  defp collect_search_paths(%{"OrStatement" => %{"Statements" => stmts}}),
    do: Enum.flat_map(stmts, &collect_search_paths/1)

  defp collect_search_paths(%{
         "ByteMatchStatement" => %{
           "FieldToMatch" => %{"UriPath" => _},
           "SearchString" => s
         }
       }) do
    case Base.decode64(s) do
      {:ok, decoded} -> [decoded]
      _ -> []
    end
  end

  defp collect_search_paths(_), do: []
end
