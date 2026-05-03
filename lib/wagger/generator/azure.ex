defmodule Wagger.Generator.Azure do
  @moduledoc """
  Azure Front Door WAF policy generator implementing the `Wagger.Generator` behaviour.

  Produces an Azure Front Door WAF policy JSON document with:
  - A path-allowlist custom rule using `RegEx` operator with `negateCondition: true`,
    blocking any request whose URI does not match one of the known route patterns
  - Per-method-set `MethodEnforcementRule` entries (priority 2..N) that block
    requests whose URI matches a bucket's paths but whose method is not in
    the bucket's allowed method-set
  - Per-route `RateLimitRule` entries for routes that carry a `rate_limit` value;
    the limit is multiplied by 5 to express a 5-minute window (matching AWS behaviour)
  - Configurable `Prevention` or `Detection` mode via `config.mode`

  ## Why two layers of allowlist enforcement

  Azure custom rule `matchConditions` AND together within a rule, so a single
  negated rule can express "URI not in allowlist" but not "(method, path)
  not in allowlist" when more than one method-set exists. We layer:

  1. The path-allowlist rule (priority 1) blocks unknown URIs.
  2. One method-enforcement rule per method-set bucket (priority 2..N) blocks
     requests where the URI is in the bucket's paths but the method is not
     in the bucket's allowed methods.

  Bucketing uses explode-then-cluster: explode each route into atomic
  (method, path) pairs, regroup by path to reconstruct effective method-sets,
  then group paths sharing a method-set. Each path lands in exactly one
  bucket and one enforcement rule.

  The `serialize/2` callback emits a JSON string matching the Azure Front Door
  WAF policy `properties` envelope expected by ARM / Bicep deployments.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  # Base priority for the allowlist match rule; method-enforcement rules
  # occupy 2..(2 + #buckets - 1); rate-limit rules start at 100+.
  @allowlist_priority 1
  @method_enforcement_priority_base 2
  @rate_limit_priority_base 100
  @rate_limit_duration_minutes 5

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-azure-fd.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    mode = config[:mode] || config["mode"] || "Prevention"

    normalized = Enum.map(routes, &normalize/1)

    allowlist_rule = build_allowlist_rule(normalized, prefix)
    method_enforcement_rules = build_method_enforcement_rules(normalized, prefix)

    rate_limit_rules =
      normalized
      |> Enum.reject(&is_nil(&1.rate_limit))
      |> Enum.with_index()
      |> Enum.map(fn {route, idx} ->
        build_rate_limit_rule(route, prefix, @rate_limit_priority_base + idx)
      end)

    all_rules = [allowlist_rule | method_enforcement_rules] ++ rate_limit_rules

    %{
      "azure-fd-policy" => %{
        "policy-name" => prefix,
        "mode" => mode,
        "custom-rules" => %{
          "rules" => all_rules
        }
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    policy = instance["azure-fd-policy"]
    mode = policy["mode"]
    rules = policy["custom-rules"]["rules"]

    serialized_rules =
      Enum.map(rules, fn rule ->
        base = %{
          "name" => rule["name"],
          "priority" => rule["priority"],
          "ruleType" => rule["rule-type"],
          "action" => rule["action"],
          "matchConditions" => Enum.map(rule["match-conditions"], &serialize_match_condition/1)
        }

        case rule["rule-type"] do
          "RateLimitRule" ->
            base
            |> Map.put("rateLimitThreshold", rule["rate-limit-threshold"])
            |> Map.put("rateLimitDurationInMinutes", rule["rate-limit-duration-in-minutes"])

          _ ->
            base
        end
      end)

    document = %{
      "properties" => %{
        "customRules" => %{
          "rules" => serialized_rules
        },
        "policySettings" => %{
          "mode" => mode,
          "enabledState" => "Enabled"
        }
      }
    }

    Jason.encode!(document, pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      rate_limit: route[:rate_limit] || route["rate_limit"]
    }
  end

  defp build_allowlist_rule(routes, prefix) do
    patterns = Enum.map(routes, &PathHelper.to_regex/1)

    %{
      "name" => "#{prefix}AllowKnownPaths",
      "priority" => @allowlist_priority,
      "rule-type" => "MatchRule",
      "action" => "Block",
      "match-conditions" => [
        %{
          "match-variable" => "RequestUri",
          "operator" => "RegEx",
          "negate-condition" => true,
          "match-values" => patterns,
          "transforms" => ["UrlDecode", "Lowercase"]
        }
      ]
    }
  end

  # One Block rule per method-set bucket. Fires when the URI matches a
  # bucket's paths AND the method is NOT in the bucket's allowed methods.
  # Both conditions AND together within a single Azure custom rule.
  defp build_method_enforcement_rules(routes, prefix) do
    routes
    |> PathHelper.partition_by_method_set(&PathHelper.to_regex/1)
    |> Enum.with_index()
    |> Enum.map(fn {{methods, regexes}, idx} ->
      %{
        "name" => "#{prefix}EnforceMethods#{idx}",
        "priority" => @method_enforcement_priority_base + idx,
        "rule-type" => "MatchRule",
        "action" => "Block",
        "match-conditions" => [
          %{
            "match-variable" => "RequestUri",
            "operator" => "RegEx",
            "negate-condition" => false,
            "match-values" => regexes,
            "transforms" => ["UrlDecode", "Lowercase"]
          },
          %{
            "match-variable" => "RequestMethod",
            "operator" => "Equal",
            "negate-condition" => true,
            "match-values" => methods,
            "transforms" => []
          }
        ]
      }
    end)
  end

  defp build_rate_limit_rule(route, prefix, priority) do
    pattern = PathHelper.to_regex(route)
    suffix = sanitize_path(route.path)

    %{
      "name" => "#{prefix}RateLimit#{suffix}",
      "priority" => priority,
      "rule-type" => "RateLimitRule",
      "action" => "Block",
      "rate-limit-threshold" => route.rate_limit * @rate_limit_duration_minutes,
      "rate-limit-duration-in-minutes" => @rate_limit_duration_minutes,
      "match-conditions" => [
        %{
          "match-variable" => "RequestUri",
          "operator" => "RegEx",
          "negate-condition" => false,
          "match-values" => [pattern],
          "transforms" => ["UrlDecode", "Lowercase"]
        }
      ]
    }
  end

  defp serialize_match_condition(cond_map) do
    %{
      "matchVariable" => cond_map["match-variable"],
      "operator" => cond_map["operator"],
      "negateCondition" => cond_map["negate-condition"],
      "matchValue" => cond_map["match-values"],
      "transforms" => cond_map["transforms"]
    }
  end

  defp sanitize_path(path) do
    path
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    |> String.trim("_")
  end
end
