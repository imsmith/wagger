defmodule Wagger.Generator.Gcp do
  @moduledoc """
  GCP Cloud Armor security policy generator implementing the `Wagger.Generator` behaviour.

  ## Role in the GCP two-layer architecture

  Cloud Armor is **defense-in-depth behind the URL Map**. It does NOT
  enumerate allowed `(method, path)` pairs — that is `Wagger.Generator.GcpUrlMap`'s
  responsibility. Cloud Armor's role is:

  - **Rate limiting** — `rate_based_ban` rules at priority 1000+ applied per-path.
  - **IP / geo posture** — one allow rule (priority 2000) admits traffic from
    declared sources; traffic not matching is denied by the default rule.
  - **Future** — preconfigured WAF rules, bot management, etc.

  Because the URL Map already gates `(method, path)`, the Cloud Armor default
  rule is set to `deny(403)` rather than `allow`. This makes the posture model
  explicit: only traffic from declared sources (or all sources if no posture
  is declared) reaches the backend service.

  ## Posture dispatch table

  The single posture allow rule (priority `#{2000}`) is built from two optional
  config keys: `allow_ip_ranges` (list of CIDR strings) and `allow_regions`
  (list of region codes like `"US"`, `"GB"`):

  | `allow_ip_ranges` | `allow_regions` | Allow rule shape |
  |-------------------|-----------------|------------------|
  | nil / empty       | nil / empty     | `versioned-expr` SRC_IPS_V1 `srcIpRanges: ["*"]` (permissive) |
  | declared          | nil / empty     | `versioned-expr` SRC_IPS_V1 `srcIpRanges: <CIDRs>` |
  | nil / empty       | declared        | CEL `origin.region_code in [...]` |
  | declared          | declared        | CEL AND of IP ranges + region code |

  In all cases the default rule (priority 2147483647) is `deny(403)`.

  ## Rule priority layout

      1000..1999  rate_based_ban rules (one per rate-limited route)
      2000        posture allow rule (one rule, combined expression)
      2147483647  default deny(403) — (method, path) gating handled by URL Map
  """

  @behaviour Wagger.Generator

  @rate_rule_base_priority 1000
  @posture_allow_priority_base 2000
  @default_priority 2_147_483_647

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
    posture_allow_rules = build_posture_allow_rules(config)
    default_rule = build_default_rule()

    rules = rate_rules ++ posture_allow_rules ++ [default_rule]

    %{
      "gcp-armor-config" => %{
        "policy-name" => "#{prefix}-security-policy",
        "description" => "WAF policy for #{prefix}",
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
          regex = Wagger.Generator.PathHelper.to_regex(route)

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

  defp build_posture_allow_rules(config) do
    ip_ranges = config[:allow_ip_ranges] || config["allow_ip_ranges"]
    regions = config[:allow_regions] || config["allow_regions"]

    ip_ranges = if ip_ranges == [], do: nil, else: ip_ranges
    regions = if regions == [], do: nil, else: regions

    rule =
      cond do
        ip_ranges == nil and regions == nil ->
          %{
            "priority" => @posture_allow_priority_base,
            "description" =>
              "Permissive allow — Cloud Armor is defense-in-depth behind URL Map; (method, path) allowlisting handled there.",
            "action" => "allow",
            "cel-expression" => nil,
            "match-type" => "versioned-expr",
            "src-ip-ranges" => ["*"]
          }

        ip_ranges != nil and regions == nil ->
          %{
            "priority" => @posture_allow_priority_base,
            "description" => "Allow declared IP ranges",
            "action" => "allow",
            "cel-expression" => nil,
            "match-type" => "versioned-expr",
            "src-ip-ranges" => ip_ranges
          }

        ip_ranges == nil and regions != nil ->
          region_list = regions |> Enum.map(&"'#{&1}'") |> Enum.join(", ")
          expr = "origin.region_code in [#{region_list}]"

          %{
            "priority" => @posture_allow_priority_base,
            "description" => "Allow declared regions: #{Enum.join(regions, ", ")}",
            "action" => "allow",
            "cel-expression" => expr,
            "match-type" => "expr"
          }

        true ->
          # Both declared — AND the IP range checks with the region check
          ip_checks =
            ip_ranges
            |> Enum.map(&"inIpRange(origin.ip, '#{&1}')")
            |> Enum.join(" || ")

          ip_expr = if length(ip_ranges) > 1, do: "(#{ip_checks})", else: ip_checks
          region_list = regions |> Enum.map(&"'#{&1}'") |> Enum.join(", ")
          expr = "(origin.region_code in [#{region_list}]) && #{ip_expr}"

          %{
            "priority" => @posture_allow_priority_base,
            "description" =>
              "Allow declared regions (#{Enum.join(regions, ", ")}) AND IP ranges (#{Enum.join(ip_ranges, ", ")})",
            "action" => "allow",
            "cel-expression" => expr,
            "match-type" => "expr"
          }
      end

    [rule]
  end

  defp build_default_rule do
    %{
      "priority" => @default_priority,
      "description" => "Default deny — (method, path) allowlisting handled by URL Map",
      "action" => "deny(403)",
      "cel-expression" => nil,
      "match-type" => "versioned-expr"
    }
  end

  # ---------------------------------------------------------------------------
  # Match shape
  # ---------------------------------------------------------------------------

  defp build_match(%{"match-type" => "versioned-expr"} = rule) do
    src_ip_ranges = Map.get(rule, "src-ip-ranges", ["*"])

    %{
      "versionedExpr" => "SRC_IPS_V1",
      "config" => %{"srcIpRanges" => src_ip_ranges}
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
