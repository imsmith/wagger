defmodule Wagger.Generator.Cloudflare do
  @moduledoc """
  Cloudflare firewall rules generator implementing the `Wagger.Generator` behaviour.

  Produces a JSON array of Cloudflare Ruleset Engine firewall rules with:
  - A single `block` rule using `not (expr1 or expr2 or ...)` to allowlist known paths
  - Optional `managed_challenge` rules per route for rate limiting

  Expression language mapping:
  - Exact path without params: `http.request.uri.path eq "/path"`
  - Prefix path: `starts_with(http.request.uri.path, "/path")`
  - Exact path with `{param}` placeholders or explicit regex type:
    `http.request.uri.path matches "^regex$"`
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-cloudflare.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]

    normalized = Enum.map(routes, &normalize/1)

    allowlist_expr = build_allowlist_expression(normalized)

    block_rule = %{
      "description" => "[#{prefix}] Block unknown paths",
      "expression" => allowlist_expr,
      "action" => "block",
      "enabled" => true
    }

    rate_limit_rules =
      normalized
      |> Enum.filter(&(not is_nil(&1.rate_limit)))
      |> Enum.map(fn route ->
        %{
          "description" => "[#{prefix}] Rate limit: #{route.path}",
          "expression" => build_path_expression(route),
          "action" => "managed_challenge",
          "enabled" => true,
          "ratelimit" => %{
            "period" => 60,
            "requests_per_period" => route.rate_limit,
            "mitigation_timeout" => 600,
            "characteristics" => ["ip.src"]
          }
        }
      end)

    rules = [block_rule | rate_limit_rules]

    %{
      "cloudflare-config" => %{
        "config-name" => prefix,
        "generated-at" => iso8601_now(),
        "rules" => rules
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    rules =
      instance["cloudflare-config"]["rules"]
      |> Enum.map(&rule_to_output/1)

    comment = format_expression_comment(rules)
    json = Jason.encode!(rules, pretty: true)

    comment <> json
  end

  defp format_expression_comment(rules) do
    block_rule = Enum.find(rules, &(&1["action"] == "block"))

    if block_rule do
      expr = block_rule["expression"]
      # Break "not (A or B or C)" into readable lines
      inner =
        expr
        |> String.trim_leading("not (")
        |> String.trim_trailing(")")
        |> String.split(" or ")
        |> Enum.map_join("\n#     or ", &String.trim/1)

      """
      # Cloudflare Firewall Rules
      #
      # Block expression (human-readable):
      #   not (
      #     #{inner}
      #   )
      #

      """
    else
      ""
    end
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

  # Allowlist semantics are over `(method, path)` pairs, not paths alone.
  # We partition routes by their effective method-set (explode → cluster
  # by path → cluster by reconstructed set) so each path appears under
  # exactly one method check, then emit:
  #
  #   not ((method_check_1 and (p1_expr or p2_expr)) or
  #        (method_check_2 and (p3_expr)) or ...)
  #
  # Single-method buckets use `eq`; multi-method buckets use Cloudflare's
  # set syntax `in {"GET" "POST"}`.
  defp build_allowlist_expression(routes) do
    bucket_exprs =
      routes
      |> PathHelper.partition_by_method_set(& &1)
      |> Enum.map(fn {methods, bucket_routes} ->
        method_check = build_method_check(methods)
        path_exprs = Enum.map(bucket_routes, &build_path_expression/1)

        path_clause =
          case path_exprs do
            [single] -> single
            many -> "(" <> Enum.join(many, " or ") <> ")"
          end

        "(#{method_check} and #{path_clause})"
      end)

    inner = Enum.join(bucket_exprs, " or ")
    "not (#{inner})"
  end

  defp build_method_check([single]), do: ~s|http.request.method eq "#{single}"|

  defp build_method_check(methods) do
    list = methods |> Enum.map(&~s|"#{&1}"|) |> Enum.join(" ")
    "http.request.method in {#{list}}"
  end

  defp build_path_expression(%{path: path, path_type: "prefix"}) do
    # Ensure trailing slash for prefix matching
    prefix =
      if String.ends_with?(path, "/") do
        path
      else
        path <> "/"
      end

    ~s|starts_with(http.request.uri.path, "#{prefix}")|
  end

  defp build_path_expression(%{path: path, path_type: "exact"}) do
    if has_params?(path) do
      regex = PathHelper.to_regex(%{path: path, path_type: "exact"})
      ~s|http.request.uri.path matches "#{regex}"|
    else
      ~s|http.request.uri.path eq "#{path}"|
    end
  end

  defp build_path_expression(%{path: path, path_type: "regex"}) do
    ~s|http.request.uri.path matches "#{path}"|
  end

  defp has_params?(path), do: String.contains?(path, "{")

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp rule_to_output(rule) do
    base = %{
      "description" => rule["description"],
      "expression" => rule["expression"],
      "action" => rule["action"],
      "enabled" => rule["enabled"]
    }

    case Map.get(rule, "ratelimit") do
      nil ->
        base

      rl ->
        Map.put(base, "ratelimit", %{
          "period" => rl["period"],
          "requests_per_period" => rl["requests_per_period"],
          "mitigation_timeout" => rl["mitigation_timeout"],
          "characteristics" => rl["characteristics"]
        })
    end
  end
end
