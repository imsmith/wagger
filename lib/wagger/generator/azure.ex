defmodule Wagger.Generator.Azure do
  @moduledoc """
  Azure Front Door WAF policy generator implementing the `Wagger.Generator` behaviour.

  Produces an Azure Front Door WAF policy JSON document with:
  - A path-allowlist custom rule using `RegEx` operator with `negateCondition: true`,
    blocking any request whose URI does not match one of the known route patterns
  - Per-route `RateLimitRule` entries for routes that carry a `rate_limit` value;
    the limit is multiplied by 5 to express a 5-minute window (matching AWS behaviour)
  - Configurable `Prevention` or `Detection` mode via `config.mode`

  The `serialize/2` callback emits a JSON string matching the Azure Front Door
  WAF policy `properties` envelope expected by ARM / Bicep deployments.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  # Base priority for the allowlist match rule; rate-limit rules start above it.
  @allowlist_priority 1
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

    rate_limit_rules =
      normalized
      |> Enum.reject(&is_nil(&1.rate_limit))
      |> Enum.with_index()
      |> Enum.map(fn {route, idx} ->
        build_rate_limit_rule(route, prefix, @rate_limit_priority_base + idx)
      end)

    all_rules = [allowlist_rule | rate_limit_rules]

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
