defmodule Wagger.Generator.Nginx do
  @moduledoc """
  Nginx WAF config generator implementing the `Wagger.Generator` behaviour.

  Produces an nginx.conf-style allowlist configuration with:
  - A `map` directive for path validation (blocks unknown paths with 403)
  - `server` block with per-route `location` directives
  - Optional `limit_req` rate limiting per location
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.PathHelper

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-nginx.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    upstream = config[:upstream] || config["upstream"]

    entries =
      Enum.map(routes, fn route ->
        %{
          "pattern" => PathHelper.to_regex(normalize(route)),
          "value" => "1"
        }
      end)

    locations =
      Enum.map(routes, fn route ->
        r = normalize(route)
        {match_atom, loc_path} = PathHelper.to_nginx_location(r)
        methods = r.methods
        rate_limit = r.rate_limit

        base = %{
          "path" => loc_path,
          "match-type" => Atom.to_string(match_atom),
          "allowed-methods" => methods,
          "upstream" => upstream
        }

        if is_nil(rate_limit) do
          base
        else
          zone_name = "#{prefix}_#{sanitize_path(loc_path)}"
          burst = max(1, trunc(rate_limit * 0.2))
          Map.put(base, "rate-limit", %{"zone-name" => zone_name, "burst" => burst})
        end
      end)

    %{
      "nginx-config" => %{
        "config-name" => prefix,
        "generated-at" => iso8601_now(),
        "path-map" => %{
          "default-value" => "0",
          "entries" => entries
        },
        "locations" => locations
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["nginx-config"]
    config_name = cfg["config-name"]
    generated_at = cfg["generated-at"]
    path_map = cfg["path-map"]
    locations = cfg["locations"]

    map_entries =
      Enum.map_join(path_map["entries"], "\n", fn e ->
        "  ~#{e["pattern"]}  1;"
      end)

    location_blocks =
      Enum.map_join(locations, "\n\n", fn loc ->
        render_location(loc)
      end)

    """
    # WAF-style allowlist for #{config_name}
    # Generated #{generated_at}

    map $request_uri $valid_path {
      default 0;
    #{map_entries}
    }

    server {
      if ($valid_path = 0) {
        return 403;
      }

    #{indent(location_blocks, 2)}
    }
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

  defp sanitize_path(path) do
    String.replace(path, ~r/[^a-zA-Z0-9]/, "_")
  end

  defp iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp render_location(loc) do
    match_type = loc["match-type"]
    path = loc["path"]
    methods = loc["allowed-methods"]
    upstream = loc["upstream"]
    rate_limit = Map.get(loc, "rate-limit")

    directive = location_directive(match_type, path)
    methods_str = Enum.join(methods, " ")

    rate_limit_line =
      if rate_limit do
        "  limit_req zone=#{rate_limit["zone-name"]} burst=#{rate_limit["burst"]} nodelay;\n"
      else
        ""
      end

    block =
      """
      location #{directive} {
        limit_except #{methods_str} {
          deny all;
        }
      #{rate_limit_line}  proxy_pass #{upstream};
      }
      """
      |> String.trim_trailing()

    block
  end

  defp location_directive("exact", path), do: "= #{path}"
  defp location_directive("prefix", path), do: path
  defp location_directive("regex", path), do: "~ #{path}"

  defp indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
