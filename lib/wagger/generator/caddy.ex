defmodule Wagger.Generator.Caddy do
  @moduledoc """
  Caddy WAF config generator implementing the `Wagger.Generator` behaviour.

  Produces a Caddyfile-style allowlist configuration with:
  - Named matcher blocks (`@name`) using `path` or `path_regexp` directives
  - `route` blocks with `reverse_proxy` and optional `rate_limit`
  - A catch-all `respond 403` to block unmatched requests
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-caddy.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    upstream = config[:upstream] || config["upstream"]

    matchers =
      Enum.map(routes, fn route ->
        r = normalize(route)
        {match_atom, loc_path} = PathHelper.to_nginx_location(r)
        name = matcher_name(r.path)

        {caddy_type, pattern} = caddy_match(match_atom, loc_path, r)

        base = %{
          "name" => name,
          "match-type" => caddy_type,
          "pattern" => pattern,
          "allowed-methods" => r.methods
        }

        if is_nil(r.rate_limit) do
          base
        else
          Map.put(base, "rate-limit", %{"per-minute" => r.rate_limit})
        end
      end)

    %{
      "caddy-config" => %{
        "config-name" => prefix,
        "upstream" => upstream,
        "matchers" => matchers
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["caddy-config"]
    config_name = cfg["config-name"]
    upstream = cfg["upstream"]
    matchers = cfg["matchers"]

    matcher_blocks =
      Enum.map_join(matchers, "\n\n", fn m ->
        render_matcher(m)
      end)

    route_blocks =
      Enum.map_join(matchers, "\n\n", fn m ->
        render_route(m, upstream)
      end)

    """
    # WAF-style allowlist for #{config_name}

    #{matcher_blocks}

    #{route_blocks}

    # Block everything else
    respond 403
    """
    |> String.trim_trailing()
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

  # Convert nginx-style match atom + path to Caddy matcher type and pattern.
  # :exact without params → path /exact/path
  # :prefix → path /prefix/*
  # :regex or :exact with params → path_regexp ^pattern$
  defp caddy_match(:exact, path, _r) do
    {"path", path}
  end

  defp caddy_match(:prefix, path, _r) do
    # path already has trailing slash from PathHelper; append * for wildcard
    pattern =
      if String.ends_with?(path, "/") do
        path <> "*"
      else
        path <> "/*"
      end

    {"path", pattern}
  end

  defp caddy_match(:regex, path, _r) do
    {"path_regexp", path}
  end

  defp matcher_name(path) do
    path
    |> String.replace_leading("/", "")
    |> String.replace(~r/[^a-zA-Z0-9]/, "_")
    |> String.trim("_")
  end

  defp render_matcher(m) do
    methods_str = Enum.join(m["allowed-methods"], " ")

    """
    @#{m["name"]} {
      #{m["match-type"]} #{m["pattern"]}
      method #{methods_str}
    }
    """
    |> String.trim_trailing()
  end

  defp render_route(m, upstream) do
    rate_limit_block =
      case Map.get(m, "rate-limit") do
        nil ->
          ""

        rl ->
          "  rate_limit {per_minute #{rl["per-minute"]}}\n"
      end

    """
    route @#{m["name"]} {
    #{rate_limit_block}  reverse_proxy #{upstream}
    }
    """
    |> String.trim_trailing()
  end
end
