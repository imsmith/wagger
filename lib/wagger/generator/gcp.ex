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

  Cloud Armor enforces a 2048-char-per-rule expression limit. A single
  combined `!matches(p1) && !matches(p2) && ...` deny rule exceeds the
  limit for any non-trivial allowlist (~30-40 paths). Inverting to many
  small `matches(p1) || matches(p2) || ...` allow rules with a final
  catch-all deny preserves allowlist semantics while staying under the
  limit. Cloud Armor's per-policy rule limit is 200, so this scales to
  several thousand paths.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @rate_rule_base_priority 1000
  @allow_rule_base_priority 2000
  @deny_all_priority 3000
  @default_priority 2_147_483_647

  # Char budget per allow rule expression. Cloud Armor's hard limit is 2048;
  # 1900 leaves margin for syntax overhead and any future regex growth.
  @max_expression_chars 1900

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-gcp-armor.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    normalized = Enum.map(routes, &normalize/1)
    regexes = Enum.map(normalized, &PathHelper.to_regex/1)

    rate_rules = build_rate_rules(normalized)
    allow_rules = build_allow_rules(regexes)
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

  defp build_allow_rules(regexes) do
    chunks = chunk_regexes(regexes, @max_expression_chars)
    total = length(chunks)

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      expr =
        chunk
        |> Enum.map(&"request.path.matches('#{&1}')")
        |> Enum.join(" || ")

      %{
        "priority" => @allow_rule_base_priority + idx,
        "description" => "Allow known paths (chunk #{idx + 1}/#{total})",
        "action" => "allow",
        "cel-expression" => expr,
        "match-type" => "expr"
      }
    end)
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

  # Greedy bin-packing: walk regexes, accumulate into the current chunk
  # until adding another would exceed max_chars (counting separator overhead).
  # Then start a new chunk. Regex order is preserved within chunks.
  defp chunk_regexes(regexes, max_chars) do
    {chunks, last} =
      Enum.reduce(regexes, {[], {[], 0}}, fn regex, {chunks, {cur, cur_size}} ->
        term_size = String.length(regex) + 25
        sep_size = if cur == [], do: 0, else: 4
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
