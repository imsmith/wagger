defmodule Wagger.Generator.GcpUrlMapTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.GcpUrlMap

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}
  ]
  @config %{prefix: "myapp"}

  # ---------------------------------------------------------------------------
  # Describe block 1: map_routes/2 shape
  # ---------------------------------------------------------------------------

  describe "map_routes/2 top-level shape" do
    setup do
      %{instance: GcpUrlMap.map_routes(@routes, @config)}
    end

    test "url-map-name derived from prefix", %{instance: instance} do
      assert instance["gcp-urlmap-config"]["url-map-name"] == "myapp-allowlist"
    end

    test "default-service is deny backend placeholder", %{instance: instance} do
      assert instance["gcp-urlmap-config"]["default-service"] == "__DENY_BACKEND__"
    end

    test "host-rules and path-matchers present", %{instance: instance} do
      cfg = instance["gcp-urlmap-config"]
      assert is_list(cfg["host-rules"])
      assert is_list(cfg["path-matchers"])
    end

    test "exactly one host-rule with hosts [*] and a path-matcher-name", %{instance: instance} do
      host_rules = instance["gcp-urlmap-config"]["host-rules"]
      assert length(host_rules) == 1
      hr = hd(host_rules)
      assert hr["hosts"] == ["*"]
      assert is_binary(hr["path-matcher-name"])
    end

    test "host-rule path-matcher-name matches path-matcher name", %{instance: instance} do
      cfg = instance["gcp-urlmap-config"]
      pm_name = hd(cfg["path-matchers"])["name"]
      assert hd(cfg["host-rules"])["path-matcher-name"] == pm_name
    end

    test "exactly one path-matcher named allowlist-matcher", %{instance: instance} do
      pms = instance["gcp-urlmap-config"]["path-matchers"]
      assert length(pms) == 1
      pm = hd(pms)
      assert pm["name"] == "allowlist-matcher"
      assert pm["default-service"] == "__DENY_BACKEND__"
      assert is_list(pm["route-rules"])
    end

    test "route-rule count equals distinct method-sets + 1 for default-deny", %{instance: instance} do
      # @routes has 3 distinct method-sets: [DELETE,GET,PUT], [GET], [GET,POST]
      route_rules = get_in(instance, ["gcp-urlmap-config", "path-matchers"]) |> hd() |> Map.get("route-rules")
      distinct_method_sets = 3
      assert length(route_rules) == distinct_method_sets + 1
    end

    test "default-deny is the last route-rule with highest priority number", %{instance: instance} do
      route_rules = get_in(instance, ["gcp-urlmap-config", "path-matchers"]) |> hd() |> Map.get("route-rules")
      last = List.last(route_rules)
      max_priority = Enum.max_by(route_rules, & &1["priority"])["priority"]
      assert last["priority"] == max_priority
      assert last["service"] == "__DENY_BACKEND__"
      mr = hd(last["match-rules"])
      assert mr["path-template-match"] == "/{path=**}"
      refute Map.has_key?(mr, "header-matches")
    end

    test "all non-default route-rules have service __KNOWN_TRAFFIC_BACKEND__", %{instance: instance} do
      route_rules = get_in(instance, ["gcp-urlmap-config", "path-matchers"]) |> hd() |> Map.get("route-rules")
      allow_rules = Enum.filter(route_rules, &(&1["service"] != "__DENY_BACKEND__"))
      assert length(allow_rules) > 0

      for rr <- allow_rules do
        assert rr["service"] == "__KNOWN_TRAFFIC_BACKEND__"
      end
    end

    test "match-rule count per route-rule matches routes in that bucket", %{instance: instance} do
      route_rules = get_in(instance, ["gcp-urlmap-config", "path-matchers"]) |> hd() |> Map.get("route-rules")
      # [DELETE,GET,PUT] bucket: 1 route (/api/users/{id})
      # [GET] bucket: 2 routes (/health, /static/)
      # [GET,POST] bucket: 1 route (/api/users)
      allow_rules = Enum.filter(route_rules, &(&1["service"] != "__DENY_BACKEND__"))
      mr_counts = allow_rules |> Enum.map(&length(&1["match-rules"])) |> Enum.sort()
      assert mr_counts == [1, 1, 2]
    end
  end

  # ---------------------------------------------------------------------------
  # Describe block 2: path-type dispatch
  # ---------------------------------------------------------------------------

  describe "path-type dispatch" do
    test "exact path with no params emits full-path-match" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      mr = first_match_rule(instance)
      assert mr["full-path-match"] == "/health"
      refute Map.has_key?(mr, "path-template-match")
    end

    test "exact path with {param} emits path-template-match with {param=*} substitution" do
      routes = [%{path: "/users/{id}", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      mr = first_match_rule(instance)
      assert mr["path-template-match"] == "/users/{id=*}"
      refute Map.has_key?(mr, "full-path-match")
    end

    test "prefix path emits prefix-match with trailing slash" do
      routes = [%{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      mr = first_match_rule(instance)
      assert mr["prefix-match"] == "/static/"
      refute Map.has_key?(mr, "full-path-match")
    end

    test "prefix path without trailing slash gets one added" do
      routes = [%{path: "/static", methods: ["GET"], path_type: "prefix", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      mr = first_match_rule(instance)
      assert mr["prefix-match"] == "/static/"
    end

    test "regex path emits regex-match passthrough" do
      routes = [%{path: "^/v[12]/.*$", methods: ["GET"], path_type: "regex", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      mr = first_match_rule(instance)
      assert mr["regex-match"] == "^/v[12]/.*$"
      refute Map.has_key?(mr, "full-path-match")
    end
  end

  # ---------------------------------------------------------------------------
  # Describe block 3: method-set bucketing
  # ---------------------------------------------------------------------------

  describe "method-set bucketing" do
    test "single-method bucket emits exact-match header" do
      routes = [%{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      hm = first_match_rule(instance)["header-matches"] |> hd()
      assert hm["header-name"] == ":method"
      assert hm["exact-match"] == "GET"
      refute Map.has_key?(hm, "regex-match")
    end

    test "multi-method bucket emits regex-match alternation sorted with |" do
      routes = [%{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      hm = first_match_rule(instance)["header-matches"] |> hd()
      assert hm["header-name"] == ":method"
      assert hm["regex-match"] == "GET|POST"
      refute Map.has_key?(hm, "exact-match")
    end

    test "multi-method alternation is sorted" do
      # POST before GET in input; should sort to GET|POST
      routes = [%{path: "/a", methods: ["POST", "GET"], path_type: "exact", rate_limit: nil}]
      instance = GcpUrlMap.map_routes(routes, @config)
      hm = first_match_rule(instance)["header-matches"] |> hd()
      assert hm["regex-match"] == "GET|POST"
    end

    test "distinct method-sets produce distinct route-rules" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      instance = GcpUrlMap.map_routes(routes, @config)
      route_rules = allow_rules(instance)
      assert length(route_rules) == 2
    end

    test "routes sharing a method-set are packed into one route-rule" do
      routes = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/b", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/c", methods: ["GET"], path_type: "exact", rate_limit: nil}
      ]

      instance = GcpUrlMap.map_routes(routes, @config)
      allow = allow_rules(instance)
      assert length(allow) == 1
      assert length(hd(allow)["match-rules"]) == 3
    end

    test "atomic explosion equivalence: [GET,POST] /a == [GET] /a + [POST] /a" do
      multi = [%{path: "/a", methods: ["GET", "POST"], path_type: "exact", rate_limit: nil}]

      atomic = [
        %{path: "/a", methods: ["GET"], path_type: "exact", rate_limit: nil},
        %{path: "/a", methods: ["POST"], path_type: "exact", rate_limit: nil}
      ]

      multi_rr =
        GcpUrlMap.map_routes(multi, %{prefix: "test"})
        |> allow_rules()

      atomic_rr =
        GcpUrlMap.map_routes(atomic, %{prefix: "test"})
        |> allow_rules()

      assert multi_rr == atomic_rr
    end
  end

  # ---------------------------------------------------------------------------
  # Describe block 4: serialize/2 JSON projection
  # ---------------------------------------------------------------------------

  describe "serialize/2 JSON projection" do
    setup do
      instance = GcpUrlMap.map_routes(@routes, @config)
      json = GcpUrlMap.serialize(instance, %{})
      decoded = Jason.decode!(json)
      %{json: json, decoded: decoded}
    end

    test "renames every nested kebab key to camelCase across full document shape", %{decoded: decoded} do
      # Top-level keys
      assert Enum.sort(Map.keys(decoded)) ==
             ~w(defaultService description hostRules name pathMatchers)a
             |> Enum.map(&Atom.to_string/1)
             |> Enum.sort()

      # hostRules structure
      hr = hd(decoded["hostRules"])
      assert Enum.sort(Map.keys(hr)) == ~w(hosts pathMatcher)

      # pathMatchers structure
      pm = hd(decoded["pathMatchers"])
      assert Enum.sort(Map.keys(pm)) == ~w(defaultService name routeRules)

      # routeRules structure (allow rule)
      allow_rr =
        pm["routeRules"]
        |> Enum.reject(&(&1["service"] == "__DENY_BACKEND__"))
        |> hd()

      assert ~w(matchRules priority service) -- Map.keys(allow_rr) == []

      # matchRules structure
      mr = hd(allow_rr["matchRules"])

      # Should have one path predicate (camelCase) and headerMatches
      assert Enum.any?(
        Map.keys(mr),
        &(&1 in ~w(fullPathMatch pathTemplateMatch prefixMatch regexMatch))
      )
      assert "headerMatches" in Map.keys(mr)

      # headerMatches structure — exact values for each method combination
      hm = hd(mr["headerMatches"])
      hm_keys = Enum.sort(Map.keys(hm))
      assert hm_keys == ~w(exactMatch headerName) or
             hm_keys == ~w(headerName regexMatch)

      # Tighten: verify the exact regex value from [GET, POST] bucket (/api/users)
      mr_with_getpost_regex =
        decoded["pathMatchers"]
        |> hd()
        |> Map.get("routeRules")
        |> Enum.reject(&(&1["service"] == "__DENY_BACKEND__"))
        |> Enum.flat_map(& &1["matchRules"])
        |> Enum.find(fn m ->
          Map.get(m, "fullPathMatch") == "/api/users" and
          Enum.any?(m["headerMatches"] || [], &Map.has_key?(&1, "regexMatch"))
        end)

      assert mr_with_getpost_regex != nil
      hm_getpost =
        mr_with_getpost_regex["headerMatches"]
        |> Enum.find(&Map.has_key?(&1, "regexMatch"))
      assert hm_getpost["regexMatch"] == "GET|POST"

      # Tighten: verify the exact pathTemplateMatch value
      mr_with_tmpl =
        decoded["pathMatchers"]
        |> hd()
        |> Map.get("routeRules")
        |> Enum.flat_map(& &1["matchRules"])
        |> Enum.find(&Map.has_key?(&1, "pathTemplateMatch"))

      assert mr_with_tmpl["pathTemplateMatch"] == "/api/users/{id=*}"
    end

    test "match-rule-id is NOT present in JSON output", %{json: json} do
      refute json =~ "matchRuleId"
      refute json =~ "match-rule-id"
    end

    test "headerMatches omitted (not empty array) on default-deny match-rule", %{decoded: decoded} do
      default_deny_rr =
        decoded["pathMatchers"]
        |> hd()
        |> Map.get("routeRules")
        |> Enum.find(&(&1["service"] == "__DENY_BACKEND__"))

      deny_mr = hd(default_deny_rr["matchRules"])
      refute Map.has_key?(deny_mr, "headerMatches")
    end

    test "YANG model parses and resolves" do
      yang_src = GcpUrlMap.yang_module()
      assert {:ok, parsed} = ExYang.parse(yang_src)
      assert {:ok, _} = ExYang.resolve(parsed, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Describe block 5: backend placeholder overrides
  # ---------------------------------------------------------------------------

  describe "backend placeholder overrides" do
    test "default backends are placeholder strings" do
      instance = GcpUrlMap.map_routes(@routes, @config)
      assert instance["gcp-urlmap-config"]["default-service"] == "__DENY_BACKEND__"
      allow = allow_rules(instance)
      assert Enum.all?(allow, &(&1["service"] == "__KNOWN_TRAFFIC_BACKEND__"))
    end

    test "custom known-traffic backend propagates to all allow route-rules" do
      config = Map.put(@config, :known_traffic_backend, "my-backend")
      instance = GcpUrlMap.map_routes(@routes, config)
      allow = allow_rules(instance)
      assert Enum.all?(allow, &(&1["service"] == "my-backend"))
    end

    test "custom deny backend propagates to defaultService, path-matcher default-service, and default-deny rule" do
      config = Map.put(@config, :deny_backend, "my-deny")
      instance = GcpUrlMap.map_routes(@routes, config)
      cfg = instance["gcp-urlmap-config"]
      assert cfg["default-service"] == "my-deny"
      assert hd(cfg["path-matchers"])["default-service"] == "my-deny"
      deny_rr =
        hd(cfg["path-matchers"])["route-rules"]
        |> List.last()

      assert deny_rr["service"] == "my-deny"
    end

    test "string-keyed known_traffic_backend works same as atom key" do
      atom_config = Map.put(@config, :known_traffic_backend, "my-backend")
      string_config = Map.put(@config, "known_traffic_backend", "my-backend")

      atom_allow = allow_rules(GcpUrlMap.map_routes(@routes, atom_config))
      string_allow = allow_rules(GcpUrlMap.map_routes(@routes, string_config))

      assert Enum.map(atom_allow, & &1["service"]) == Enum.map(string_allow, & &1["service"])
      assert Enum.all?(string_allow, &(&1["service"] == "my-backend"))
    end
  end

  # ---------------------------------------------------------------------------
  # Describe block 6: full pipeline via Generator.generate/3
  # ---------------------------------------------------------------------------

  describe "generate/3 full pipeline" do
    test "returns {:ok, json_string}" do
      assert {:ok, json} = Generator.generate(GcpUrlMap, @routes, @config)
      assert is_binary(json)
    end

    test "output is valid JSON" do
      assert {:ok, json} = Generator.generate(GcpUrlMap, @routes, @config)
      assert {:ok, _} = Jason.decode(json)
    end

    test "output contains pathTemplateMatch for parameterised route" do
      assert {:ok, json} = Generator.generate(GcpUrlMap, @routes, @config)
      decoded = Jason.decode!(json)

      mr_with_tmpl =
        decoded["pathMatchers"]
        |> hd()
        |> Map.get("routeRules")
        |> Enum.flat_map(& &1["matchRules"])
        |> Enum.find(&Map.has_key?(&1, "pathTemplateMatch"))

      assert mr_with_tmpl != nil
      assert mr_with_tmpl["pathTemplateMatch"] == "/api/users/{id=*}"
    end

    test "first route-rule has lowest priority number (highest precedence)" do
      assert {:ok, json} = Generator.generate(GcpUrlMap, @routes, @config)
      decoded = Jason.decode!(json)
      route_rules = decoded["pathMatchers"] |> hd() |> Map.get("routeRules")
      priorities = Enum.map(route_rules, & &1["priority"])
      assert hd(priorities) == Enum.min(priorities)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp first_match_rule(instance) do
    get_in(instance, ["gcp-urlmap-config", "path-matchers"])
    |> hd()
    |> Map.get("route-rules")
    |> Enum.reject(&(&1["service"] == "__DENY_BACKEND__"))
    |> hd()
    |> Map.get("match-rules")
    |> hd()
  end

  defp allow_rules(instance) when is_map(instance) do
    get_in(instance, ["gcp-urlmap-config", "path-matchers"])
    |> hd()
    |> Map.get("route-rules")
    |> Enum.reject(&(&1["service"] == "__DENY_BACKEND__"))
  end

end
