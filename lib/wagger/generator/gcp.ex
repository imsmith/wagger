defmodule Wagger.Generator.Gcp do
  @moduledoc """
  GCP Cloud Armor security policy generator implementing the `Wagger.Generator` behaviour.

  Produces a Cloud Armor security policy as JSON with:
  - Per-route rate_based_ban rules at priority 1000+ (must fire first)
  - Allow rules at priority 2000+, chunked so each rule's CEL expression
    stays under Cloud Armor's per-rule 2048-character limit
  - A single catch-all deny(403) at priority 3000
  - The mandatory default rule at priority 2147483647 (preserved per
    Cloud Armor convention; unreachable in this allow-list model)

  Path matching uses CEL expressions via `request.path.matches('regex')`.

  ## Why chunked allow rules

  Cloud Armor enforces THREE per-rule limits, all of which the chunking
  must respect:

  1. **2048 chars per CEL expression** (the entire `request.path.matches(...)`)
  2. **5 sub-expressions per rule** (operands of `||` or `&&` in the CEL
     expression — a single `matches()` call is one sub-expression
     regardless of regex contents)
  3. **1024 chars per regex** (the string inside `matches('...')`)

  Limit (3) is the tightest. We pack alternation inside ONE `matches()`
  call so we stay at one sub-expression per rule:

      request.method in ['GET', 'POST'] && request.path.matches('^/p1$|^/p2$|...|^/pN$')

  Chunk so each combined regex stays under ~950 chars (margin under 1024).
  At ~30-40 chars per path, this fits ~25-30 paths per rule. The method
  check costs one additional sub-expression (the `&&` joins two operands),
  well within the 5-per-rule budget.

  ## Method enforcement and bucketing

  The semantic key for each allow entry is `(method, path)`, not `path`
  alone. To pack densely, we partition routes by their method-set:

  1. Explode each declared route into atomic `(method, path)` pairs
  2. Dedupe (two source routes can both contribute `(GET, /a)`)
  3. Group atoms by path → reconstruct each path's effective method-set
  4. Group paths by method-set → one bucket per distinct set
  5. Trie/regex-compress and chunk paths within each bucket
  6. Emit one rule per chunk with the bucket's method check ANDed in

  Each path lands in exactly one bucket (and one rule), so total path
  bytes across the policy are minimised. Real REST APIs typically have
  ~5-6 distinct method-sets (`{GET}`, `{GET,POST}`, full-CRUD, etc.).
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @rate_rule_base_priority 1000
  @allow_rule_base_priority 2000
  @deny_all_priority 3000
  @default_priority 2_147_483_647

  # Cloud Armor limits we respect:
  #   - CEL expression: 2048 chars total
  #   - Inner regex (string passed to matches()): 1024 chars
  #   - Sub-expressions: 5 per rule
  # Inner regex is the tightest binding constraint. 950 leaves margin
  # under 1024.
  @max_inner_regex_chars 950

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-gcp-armor.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    normalized = Enum.map(routes, &normalize/1)

    rate_rules = build_rate_rules(normalized)
    allow_rules = build_allow_rules(normalized)
    deny_all_rule = build_deny_all_rule()
    default_rule = build_default_rule()

    rules = rate_rules ++ allow_rules ++ [deny_all_rule, default_rule]

    %{
      "gcp-armor-config" => %{
        "policy-name" => "#{prefix}-security-policy",
        "description" => "WAF allowlist for #{prefix}",
        "generated-at" => iso8601_now(),
        "rules" => rules
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["gcp-armor-config"]

    rules =
      Enum.map(cfg["rules"], fn rule ->
        base = %{
          "priority" => rule["priority"],
          "description" => rule["description"],
          "action" => rule["action"],
          "match" => build_match(rule)
        }

        case Map.get(rule, "rate-limit-options") do
          nil ->
            base

          rl ->
            Map.put(base, "rateLimitOptions", %{
              "conformAction" => rl["conform-action"],
              "exceedAction" => rl["exceed-action"],
              "rateLimitThreshold" => %{
                "count" => rl["rate-limit-count"],
                "intervalSec" => rl["rate-limit-interval-sec"]
              }
            })
        end
      end)

    policy = %{
      "name" => cfg["policy-name"],
      "description" => cfg["description"],
      "rules" => rules
    }

    Jason.encode!(policy, pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Rule builders
  # ---------------------------------------------------------------------------

  defp build_rate_rules(normalized) do
    normalized
    |> Enum.with_index()
    |> Enum.flat_map(fn {route, idx} ->
      case route.rate_limit do
        nil ->
          []

        limit ->
          regex = PathHelper.to_regex(route)

          [
            %{
              "priority" => @rate_rule_base_priority + idx,
              "description" => "Rate limit #{route.path}",
              "action" => "rate_based_ban",
              "cel-expression" => "request.path.matches('#{regex}')",
              "match-type" => "expr",
              "rate-limit-options" => %{
                "conform-action" => "allow",
                "exceed-action" => "deny(429)",
                "rate-limit-count" => limit,
                "rate-limit-interval-sec" => 60
              }
            }
          ]
      end
    end)
  end

  defp build_allow_rules(normalized) do
    buckets = PathHelper.partition_by_method_set(normalized, &PathHelper.to_regex/1)

    rules =
      buckets
      |> Enum.flat_map(fn {methods, regexes} ->
        method_check = build_method_check(methods)
        chunks = chunk_regexes(regexes, @max_inner_regex_chars)

        Enum.map(chunks, fn chunk ->
          combined_regex = Enum.join(chunk, "|")
          expr = "#{method_check} && request.path.matches('#{combined_regex}')"

          %{
            "description" => "Allow #{Enum.join(methods, ",")} on known paths",
            "action" => "allow",
            "cel-expression" => expr,
            "match-type" => "expr"
          }
        end)
      end)

    total = length(rules)

    rules
    |> Enum.with_index()
    |> Enum.map(fn {rule, idx} ->
      rule
      |> Map.put("priority", @allow_rule_base_priority + idx)
      |> Map.update!("description", &"#{&1} (chunk #{idx + 1}/#{total})")
    end)
  end

  defp build_method_check([single]), do: "request.method == '#{single}'"

  defp build_method_check(methods) do
    list = methods |> Enum.map(&"'#{&1}'") |> Enum.join(", ")
    "request.method in [#{list}]"
  end

  defp build_deny_all_rule do
    %{
      "priority" => @deny_all_priority,
      "description" => "Block all paths not matched above",
      "action" => "deny(403)",
      "cel-expression" => nil,
      "match-type" => "versioned-expr"
    }
  end

  defp build_default_rule do
    %{
      "priority" => @default_priority,
      "description" => "Cloud Armor default rule (unreachable due to deny-all above; required by API)",
      "action" => "allow",
      "cel-expression" => nil,
      "match-type" => "versioned-expr"
    }
  end

  # ---------------------------------------------------------------------------
  # Chunking
  # ---------------------------------------------------------------------------

  # Greedy bin-packing for regex alternation. Each chunk's combined regex
  # is `r1|r2|...|rN`; size is sum(len(ri)) + (N-1) for the `|` separators.
  # Caller passes the budget for the inner regex (excludes the wrapping
  # `request.path.matches('...')`).
  defp chunk_regexes(regexes, max_chars) do
    {chunks, last} =
      Enum.reduce(regexes, {[], {[], 0}}, fn regex, {chunks, {cur, cur_size}} ->
        term_size = String.length(regex)
        sep_size = if cur == [], do: 0, else: 1
        new_size = cur_size + sep_size + term_size

        cond do
          cur == [] ->
            {chunks, {[regex], term_size}}

          new_size <= max_chars ->
            {chunks, {[regex | cur], new_size}}

          true ->
            {[Enum.reverse(cur) | chunks], {[regex], term_size}}
        end
      end)

    final =
      case last do
        {[], _} -> chunks
        {cur, _} -> [Enum.reverse(cur) | chunks]
      end

    Enum.reverse(final)
  end

  # ---------------------------------------------------------------------------
  # Match shape
  # ---------------------------------------------------------------------------

  defp build_match(%{"match-type" => "versioned-expr"}) do
    %{
      "versionedExpr" => "SRC_IPS_V1",
      "config" => %{"srcIpRanges" => ["*"]}
    }
  end

  defp build_match(%{"match-type" => "expr", "cel-expression" => expr}) do
    %{"expr" => %{"expression" => expr}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      rate_limit: route[:rate_limit] || route["rate_limit"]
    }
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
