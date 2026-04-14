defmodule Wagger.Generator.Gcp do
  @moduledoc """
  GCP Cloud Armor security policy generator implementing the `Wagger.Generator` behaviour.

  Produces a Cloud Armor security policy as JSON with:
  - A deny(403) rule blocking all requests NOT matching known paths (priority 1000)
  - Per-route rate_based_ban rules for routes with rate limits (priority 2000+)
  - A mandatory default allow rule (priority 2147483647)

  Path matching uses CEL expressions via `request.path.matches('regex')`.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @deny_priority 1000
  @default_priority 2_147_483_647
  @rate_rule_base_priority 2000

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

    deny_expr =
      regexes
      |> Enum.map(&"!request.path.matches('#{&1}')")
      |> Enum.join(" && ")

    deny_rule = %{
      "priority" => @deny_priority,
      "description" => "Block unknown paths",
      "action" => "deny(403)",
      "cel-expression" => deny_expr,
      "match-type" => "expr"
    }

    rate_rules =
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

    default_rule = %{
      "priority" => @default_priority,
      "description" => "Default allow",
      "action" => "allow",
      "cel-expression" => nil,
      "match-type" => "versioned-expr"
    }

    rules = [deny_rule] ++ rate_rules ++ [default_rule]

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

  defp build_match(%{"match-type" => "versioned-expr"}) do
    %{
      "versionedExpr" => "SRC_IPS_V1",
      "config" => %{"srcIpRanges" => ["*"]}
    }
  end

  defp build_match(%{"match-type" => "expr", "cel-expression" => expr}) do
    %{"expr" => %{"expression" => expr}}
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
