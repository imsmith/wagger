defmodule Wagger.Generator.GcpUrlMap do
  @moduledoc """
  GCP HTTP(S) Load Balancer URL Map provider implementing the `Wagger.Generator` behaviour.

  Emits a URL Map JSON fragment suitable for `gcloud compute url-maps import`.
  The output is a default-deny `(method, path)` allowlist: every `routeRule`
  permits a specific set of HTTP methods on a specific path (or template), and
  a final catch-all `routeRule` at the lowest precedence routes unmatched
  requests to a deny backend.

  ## Target platform

  Targets the **Global External Application Load Balancer** (and other modern
  ALB variants). Classic ALB is **not supported** because `pathTemplateMatch`
  — required for parameterised paths such as `/users/{id=*}` — is unavailable
  on Classic ALB.

  ## `(method, path)` bucketing algorithm

  Method enforcement is implemented via `headerMatches` on the `:method`
  pseudo-header, not via GCP's separate `httpMethod` field, so that multiple
  methods sharing the same path-set can be expressed as a regex alternation
  (`GET|POST`) rather than requiring separate rules per method.

  Routes are bucketed by their **effective method-set** via
  `PathHelper.partition_by_method_set/2`:

  1. Explode each route into atomic `{method, route}` pairs.
  2. Deduplicate by `{method, path}`.
  3. Reconstruct each path's full method-set (union of all methods across
     source routes for that path).
  4. Group paths by their effective method-set — one bucket per distinct set.

  Each bucket becomes one `routeRule` containing one `matchRule` per path in
  the bucket. Each `matchRule` carries a path predicate and a `headerMatches`
  entry on `:method`.

  ## Path predicate selection

  | `path_type` | Has `{params}`? | Predicate field       | Transformation               |
  |-------------|-----------------|-----------------------|------------------------------|
  | `"exact"`   | no              | `fullPathMatch`       | passthrough                  |
  | `"exact"`   | yes             | `pathTemplateMatch`   | `{id}` → `{id=*}`           |
  | `"prefix"`  | —               | `prefixMatch`         | trailing `/` normalised      |
  | `"regex"`   | —               | `regexMatch`          | passthrough                  |

  ## Backend-ref placeholders

  The generator emits placeholder strings when real backend service refs are
  not supplied (defaults to `@known_traffic_backend_placeholder` and
  `@deny_backend_placeholder`):

  - `@known_traffic_backend_placeholder` — routed to by all permit `routeRules`
  - `@deny_backend_placeholder` — routed to by the default-deny catch-all and used as
    the URL Map's `defaultService`

  The deployer substitutes fully-qualified refs such as
  `projects/PROJECT_ID/global/backendServices/my-backend` either by passing
  `known_traffic_backend` and `deny_backend` keys in the config map, or by
  post-processing the emitted JSON with `sed` / Terraform template injection.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @known_traffic_backend_placeholder "__KNOWN_TRAFFIC_BACKEND__"
  @deny_backend_placeholder "__DENY_BACKEND__"

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-gcp-urlmap.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]

    known_traffic_backend =
      config[:known_traffic_backend] ||
        config["known_traffic_backend"] ||
        @known_traffic_backend_placeholder

    deny_backend =
      config[:deny_backend] ||
        config["deny_backend"] ||
        @deny_backend_placeholder

    normalized = Enum.map(routes, &normalize/1)

    buckets = PathHelper.partition_by_method_set(normalized, & &1)

    {route_rules, next_priority} =
      Enum.reduce(buckets, {[], 1}, fn {methods, bucket_routes}, {acc, priority} ->
        match_rules =
          bucket_routes
          |> Enum.with_index()
          |> Enum.map(fn {route, idx} ->
            build_match_rule(route, methods, "mr-#{idx}")
          end)

        rule = %{
          "priority" => priority,
          "description" => "Allow #{Enum.join(methods, ",")} on known paths",
          "service" => known_traffic_backend,
          "match-rules" => match_rules
        }

        {acc ++ [rule], priority + 1}
      end)

    default_deny = %{
      "priority" => next_priority,
      "description" => "Default deny — unmatched (method, path) routed to deny backend",
      "service" => deny_backend,
      "match-rules" => [
        %{"match-rule-id" => "mr-0", "path-template-match" => "/{path=**}"}
      ]
    }

    route_rules_final = route_rules ++ [default_deny]

    %{
      "gcp-urlmap-config" => %{
        "url-map-name" => "#{prefix}-allowlist",
        "description" => "Wagger-generated URL Map allowlist for #{prefix}",
        "generated-at" => iso8601_now(),
        "default-service" => deny_backend,
        "host-rules" => [
          %{"path-matcher-name" => "allowlist-matcher", "hosts" => ["*"]}
        ],
        "path-matchers" => [
          %{
            "name" => "allowlist-matcher",
            "default-service" => deny_backend,
            "route-rules" => route_rules_final
          }
        ]
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["gcp-urlmap-config"]

    host_rules =
      Enum.map(cfg["host-rules"], fn hr ->
        %{
          "pathMatcher" => hr["path-matcher-name"],
          "hosts" => hr["hosts"]
        }
      end)

    path_matchers =
      Enum.map(cfg["path-matchers"], fn pm ->
        route_rules =
          Enum.map(pm["route-rules"], fn rr ->
            match_rules = Enum.map(rr["match-rules"], &serialize_match_rule/1)

            %{
              "priority" => rr["priority"],
              "description" => rr["description"],
              "service" => rr["service"],
              "matchRules" => match_rules
            }
          end)

        %{
          "name" => pm["name"],
          "defaultService" => pm["default-service"],
          "routeRules" => route_rules
        }
      end)

    doc = %{
      "name" => cfg["url-map-name"],
      "description" => cfg["description"],
      "defaultService" => cfg["default-service"],
      "hostRules" => host_rules,
      "pathMatchers" => path_matchers
    }

    Jason.encode!(doc, pretty: true)
  end

  # ---------------------------------------------------------------------------
  # Match-rule builders
  # ---------------------------------------------------------------------------

  defp build_match_rule(route, methods, id) do
    path_predicate = build_path_predicate(route)
    header_match = build_header_match(methods)

    path_predicate
    |> Map.put("match-rule-id", id)
    |> Map.merge(%{"header-matches" => [header_match]})
  end

  defp build_path_predicate(%{path: path, path_type: "exact"}) do
    if has_params?(path) do
      template = convert_params_to_template(path)
      %{"path-template-match" => template}
    else
      %{"full-path-match" => path}
    end
  end

  defp build_path_predicate(%{path: path, path_type: "prefix"}) do
    normalised =
      if String.ends_with?(path, "/") do
        path
      else
        path <> "/"
      end

    %{"prefix-match" => normalised}
  end

  defp build_path_predicate(%{path: path, path_type: "regex"}) do
    %{"regex-match" => path}
  end

  defp build_header_match([single_method]) do
    %{"header-name" => ":method", "exact-match" => single_method}
  end

  defp build_header_match(methods) do
    alternation = Enum.join(methods, "|")
    %{"header-name" => ":method", "regex-match" => alternation}
  end

  # ---------------------------------------------------------------------------
  # Serialize helpers
  # ---------------------------------------------------------------------------

  defp serialize_match_rule(mr) do
    path_part =
      cond do
        Map.has_key?(mr, "path-template-match") ->
          %{"pathTemplateMatch" => mr["path-template-match"]}

        Map.has_key?(mr, "full-path-match") ->
          %{"fullPathMatch" => mr["full-path-match"]}

        Map.has_key?(mr, "prefix-match") ->
          %{"prefixMatch" => mr["prefix-match"]}

        Map.has_key?(mr, "regex-match") ->
          %{"regexMatch" => mr["regex-match"]}

        true ->
          %{}
      end

    header_matches =
      Enum.map(mr["header-matches"] || [], fn hm ->
        base = %{"headerName" => hm["header-name"]}

        cond do
          Map.has_key?(hm, "exact-match") -> Map.put(base, "exactMatch", hm["exact-match"])
          Map.has_key?(hm, "regex-match") -> Map.put(base, "regexMatch", hm["regex-match"])
          true -> base
        end
      end)

    if header_matches == [] do
      path_part
    else
      Map.put(path_part, "headerMatches", header_matches)
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

  defp has_params?(path), do: String.contains?(path, "{")

  defp convert_params_to_template(path) do
    # Convert {param} to {param=*} for GCP pathTemplateMatch
    String.replace(path, ~r/\{([^}]+)\}/, "{\\1=*}")
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
