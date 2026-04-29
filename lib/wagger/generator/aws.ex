defmodule Wagger.Generator.Aws do
  @moduledoc """
  AWS WAF v2 Web ACL generator implementing the `Wagger.Generator` behaviour.

  Produces a JSON document conforming to the AWS WAF v2 Web ACL API format with:
  - A path allowlist rule using `NotStatement` wrapping `OrStatement` of path matchers.
    Paths with `{param}` placeholders or `regex` type use `RegexMatchStatement`.
    Exact paths without params use `ByteMatchStatement` with `EXACTLY`.
    Prefix paths use `ByteMatchStatement` with `STARTS_WITH`.
  - Method enforcement rules grouped by distinct method sets.
  - Rate-based rules using `RateBasedStatement` with AWS 5-minute window multiplication.
  - All byte match statements include `URL_DECODE` and `LOWERCASE` text transformations.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @standard_transforms [
    %{"Priority" => 0, "Type" => "URL_DECODE"},
    %{"Priority" => 1, "Type" => "LOWERCASE"}
  ]

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-aws-waf.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    scope = config[:scope] || config["scope"] || "REGIONAL"

    normalized = Enum.map(routes, &normalize/1)

    path_patterns = Enum.map(normalized, &to_path_pattern/1)

    allowlist_rule = %{
      "name" => "#{prefix}-path-allowlist",
      "priority" => 1,
      "rule-type" => "path-allowlist",
      "path-patterns" => path_patterns,
      "method-groups" => []
    }

    method_rules = build_method_rules(normalized, prefix, starting_priority: 10)

    rate_rules = build_rate_rules(normalized, prefix, starting_priority: 100)

    rules = [allowlist_rule] ++ method_rules ++ rate_rules

    %{
      "aws-waf-config" => %{
        "web-acl-name" => "#{prefix}-web-acl",
        "scope" => scope,
        "generated-at" => iso8601_now(),
        "rules" => rules
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["aws-waf-config"]
    name = cfg["web-acl-name"]
    scope = cfg["scope"]
    rules = cfg["rules"]

    aws_rules =
      rules
      |> Enum.sort_by(& &1["priority"])
      |> Enum.map(&serialize_rule/1)

    web_acl = %{
      "Name" => name,
      "Scope" => scope,
      "DefaultAction" => %{"Allow" => %{}},
      "Rules" => aws_rules,
      "VisibilityConfig" => %{
        "SampledRequestsEnabled" => true,
        "CloudWatchMetricsEnabled" => true,
        "MetricName" => name
      }
    }

    Jason.encode!(web_acl, pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Private: instance tree builders
  # ---------------------------------------------------------------------------

  defp normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      rate_limit: route[:rate_limit] || route["rate_limit"]
    }
  end

  defp to_path_pattern(%{path: path, path_type: path_type} = route) do
    cond do
      path_type == "regex" ->
        %{"path" => path, "match-type" => "REGEX"}

      path_type == "prefix" ->
        %{"path" => path, "match-type" => "STARTS_WITH"}

      path_type == "exact" && has_params?(path) ->
        regex = PathHelper.to_regex(route)
        %{"path" => regex, "match-type" => "REGEX"}

      true ->
        %{"path" => path, "match-type" => "EXACTLY"}
    end
  end

  defp build_method_rules(normalized, prefix, starting_priority: base) do
    normalized
    |> Enum.group_by(& &1.methods)
    |> Enum.with_index()
    |> Enum.map(fn {{methods, routes}, idx} ->
      paths = Enum.map(routes, & &1.path)
      group_name = "group-#{Enum.join(Enum.map(methods, &String.downcase/1), "-")}"

      %{
        "name" => "#{prefix}-methods-#{group_name}",
        "priority" => base + idx,
        "rule-type" => "method-enforcement",
        "path-patterns" => [],
        "method-groups" => [
          %{
            "group-name" => group_name,
            "methods" => methods,
            "paths" => paths
          }
        ]
      }
    end)
  end

  defp build_rate_rules(normalized, prefix, starting_priority: base) do
    normalized
    |> Enum.filter(&(not is_nil(&1.rate_limit)))
    |> Enum.with_index()
    |> Enum.map(fn {route, idx} ->
      aws_limit = route.rate_limit * 5
      safe_name = sanitize(route.path)

      %{
        "name" => "#{prefix}-rate-limit-#{safe_name}",
        "priority" => base + idx,
        "rule-type" => "rate-limit",
        "rate-limit" => aws_limit,
        "path-patterns" => [],
        "method-groups" => []
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Private: AWS JSON serializers
  # ---------------------------------------------------------------------------

  defp serialize_rule(%{"rule-type" => "path-allowlist"} = rule) do
    patterns = rule["path-patterns"]

    matchers = Enum.map(patterns, &pattern_to_statement/1)

    or_statement = %{"OrStatement" => %{"Statements" => matchers}}
    not_statement = %{"NotStatement" => %{"Statement" => or_statement}}

    %{
      "Name" => rule["name"],
      "Priority" => rule["priority"],
      "Statement" => not_statement,
      "Action" => %{"Block" => %{}},
      "VisibilityConfig" => visibility_config(rule["name"])
    }
  end

  defp serialize_rule(%{"rule-type" => "method-enforcement"} = rule) do
    groups = rule["method-groups"]

    statements =
      Enum.flat_map(groups, fn group ->
        methods = group["methods"]

        Enum.map(methods, fn method ->
          %{
            "ByteMatchStatement" => %{
              "SearchString" => Base.encode64(method),
              "FieldToMatch" => %{"Method" => %{}},
              "TextTransformations" => @standard_transforms,
              "PositionalConstraint" => "EXACTLY"
            }
          }
        end)
      end)

    allow_statement =
      case statements do
        [single] -> single
        many -> %{"OrStatement" => %{"Statements" => many}}
      end

    not_statement = %{"NotStatement" => %{"Statement" => allow_statement}}

    %{
      "Name" => rule["name"],
      "Priority" => rule["priority"],
      "Statement" => not_statement,
      "Action" => %{"Block" => %{}},
      "VisibilityConfig" => visibility_config(rule["name"])
    }
  end

  defp serialize_rule(%{"rule-type" => "rate-limit"} = rule) do
    %{
      "Name" => rule["name"],
      "Priority" => rule["priority"],
      "Statement" => %{
        "RateBasedStatement" => %{
          "Limit" => rule["rate-limit"],
          "AggregateKeyType" => "IP"
        }
      },
      "Action" => %{"Block" => %{}},
      "VisibilityConfig" => visibility_config(rule["name"])
    }
  end

  defp pattern_to_statement(%{"match-type" => "REGEX", "path" => path}) do
    %{
      "RegexMatchStatement" => %{
        "RegexString" => path,
        "FieldToMatch" => %{"UriPath" => %{}},
        "TextTransformations" => @standard_transforms
      }
    }
  end

  defp pattern_to_statement(%{"match-type" => match_type, "path" => path}) do
    %{
      "ByteMatchStatement" => %{
        "SearchString" => Base.encode64(path),
        "FieldToMatch" => %{"UriPath" => %{}},
        "TextTransformations" => @standard_transforms,
        "PositionalConstraint" => match_type
      }
    }
  end

  defp visibility_config(metric_name) do
    %{
      "SampledRequestsEnabled" => true,
      "CloudWatchMetricsEnabled" => true,
      "MetricName" => sanitize_metric(metric_name)
    }
  end

  defp sanitize(path), do: String.replace(path, ~r/[^a-zA-Z0-9]/, "_")

  defp sanitize_metric(name), do: String.replace(name, ~r/[^a-zA-Z0-9\-]/, "-")

  defp has_params?(path), do: String.contains?(path, "{")

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
