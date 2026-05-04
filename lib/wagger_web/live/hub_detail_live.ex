defmodule WaggerWeb.HubDetailLive do
  @moduledoc """
  LiveView for a public Hub application detail page.

  Shows routes with treemap navigation and a generate panel. No authentication
  required. Read-only — no editing, no import, no drift tracking.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Generator
  alias Wagger.Generator.Multi
  alias Wagger.Routes
  alias Wagger.Snapshots

  import WaggerWeb.AppDetailLive,
    only: [
      build_route_tree: 1,
      current_subtree: 2,
      tree_children: 1,
      leaf_node?: 1,
      leaf_routes: 1,
      format_path: 1,
      treemap_cell_class: 1,
      method_dot_color: 1,
      config_field_type: 1,
      config_field_key_label: 1
    ]

  @providers ~w(aws azure caddy cloudflare coraza gcp nginx zap)

  @provider_modules %{
    "nginx" => Wagger.Generator.Nginx,
    "aws" => Wagger.Generator.Aws,
    "cloudflare" => Wagger.Generator.Cloudflare,
    "azure" => Wagger.Generator.Azure,
    "gcp" => [
      {"Cloud Armor", Wagger.Generator.Gcp, "gcp-armor.json"},
      {"URL Map", Wagger.Generator.GcpUrlMap, "gcp-urlmap.json"}
    ],
    "caddy" => Wagger.Generator.Caddy,
    "coraza" => Wagger.Generator.Coraza,
    "zap" => Wagger.Generator.Zap
  }

  @provider_config_fields %{
    "nginx" => [{"prefix", "Name prefix", :text}, {"upstream", "Upstream URL", :text}],
    "caddy" => [{"prefix", "Name prefix", :text}, {"upstream", "Upstream URL", :text}],
    "aws" => [{"prefix", "Name prefix", :text}, {"scope", "REGIONAL or CLOUDFRONT", :text}],
    "cloudflare" => [{"prefix", "Name prefix", :text}],
    "azure" => [{"prefix", "Name prefix", :text}, {"mode", "Prevention or Detection", :text}],
    "gcp" => [
      {"prefix", "Name prefix", :text},
      {"allow_ip_ranges", "Allowed source IP ranges (one CIDR per line)", :textarea},
      {"allow_regions", "Allowed source regions (one ISO code per line, e.g. US, GB)", :textarea},
      {"known_traffic_backend", "Known-traffic backend ref (URL Map)", :text},
      {"deny_backend", "Deny backend ref (URL Map)", :text}
    ],
    "coraza" => [
      {"prefix", "Name prefix", :text},
      {"start_rule_id", "Starting rule ID (default 100001)", :text}
    ],
    "zap" => [
      {"prefix", "Name prefix", :text},
      {"target_url", "Target URL (or {{TARGET_URL}})", :text}
    ]
  }

  @impl true
  def mount(%{"name" => name}, _session, socket) do
    app = Applications.get_shareable_application_by_name!(name)
    routes = Routes.list_routes(app)
    route_tree = build_route_tree(routes)

    {:ok,
     socket
     |> assign(
       app: app,
       routes: routes,
       route_tree: route_tree,
       treemap_path: [],
       search_query: "",
       search_results: nil,
       all_providers: @providers,
       selected_provider: nil,
       generated_output: nil,
       active_nav: :hub,
       page_title: app.name
     )}
  end

  # -- Treemap navigation --

  @impl true
  def handle_event("treemap_drill", %{"segment" => segment}, socket) do
    new_path = socket.assigns.treemap_path ++ [segment]
    {:noreply, assign(socket, treemap_path: new_path, search_query: "", search_results: nil)}
  end

  @impl true
  def handle_event("treemap_back", %{"depth" => depth_str}, socket) do
    depth = String.to_integer(depth_str)
    new_path = Enum.take(socket.assigns.treemap_path, depth)
    {:noreply, assign(socket, treemap_path: new_path, search_query: "", search_results: nil)}
  end

  @impl true
  def handle_event("search_routes", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, search_query: "", search_results: nil)}
    else
      results =
        socket.assigns.routes
        |> Enum.filter(fn r -> String.contains?(String.downcase(r.path), String.downcase(query)) end)
        |> Enum.flat_map(fn route ->
          Enum.map(route.methods, fn method ->
            %{
              method: method,
              path: route.path,
              path_parts: format_path(route.path),
              description: route.description,
              rate_limit: route.rate_limit
            }
          end)
        end)
        |> Enum.sort_by(& &1.path)

      {:noreply, assign(socket, search_query: query, search_results: results)}
    end
  end

  # -- Generate --

  @impl true
  def handle_event("select_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, selected_provider: provider, generated_output: nil)}
  end

  @impl true
  def handle_event("generate", params, socket) do
    app = socket.assigns.app
    provider = socket.assigns.selected_provider
    provider_spec = Map.fetch!(@provider_modules, provider)
    routes = socket.assigns.routes
    route_data = Drift.normalize_for_snapshot(routes)

    raw_config = Map.drop(params, ["_target"])
    config = parse_provider_config(provider, raw_config)

    result =
      case provider_spec do
        specs when is_list(specs) -> Multi.generate(specs, route_data, config)
        module -> Generator.generate(module, route_data, config)
      end

    case result do
      {:ok, output} ->
        checksum = Drift.compute_checksum(route_data)

        {:ok, _snap} =
          Snapshots.create_snapshot(%{
            application_id: app.id,
            provider: provider,
            config_params: Jason.encode!(config),
            route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
            output: output,
            checksum: checksum
          })

        {:noreply, assign(socket, :generated_output, output)}

      {:error, %Comn.Errors.ErrorStruct{} = err} ->
        {:noreply, put_flash(socket, :error, "Generation failed: #{err.message}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Generation failed: #{inspect(reason)}")}
    end
  end

  # -- Helpers --

  @doc "Returns provider-specific configuration field definitions for the generate form."
  def config_fields_for(provider), do: Map.get(@provider_config_fields, provider, [])

  @doc "Splits a combined multi-artifact snapshot output into labeled sections."
  def split_snapshot_output(nil), do: [{nil, nil, ""}]
  def split_snapshot_output(output), do: Multi.split_artifacts(output)

  # Parse textarea and optional text config fields for GCP before dispatch.
  defp parse_provider_config("gcp", config) do
    config
    |> Map.update("allow_ip_ranges", nil, &parse_textarea_field/1)
    |> Map.update("allow_regions", nil, &parse_textarea_field/1)
    |> Map.update("known_traffic_backend", nil, &nil_if_blank/1)
    |> Map.update("deny_backend", nil, &nil_if_blank/1)
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end
  defp parse_provider_config(_provider, config), do: config

  defp parse_textarea_field(nil), do: nil
  defp parse_textarea_field(""), do: nil
  defp parse_textarea_field(value) when is_list(value), do: value
  defp parse_textarea_field(value) when is_binary(value) do
    case value |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> nil
      list -> list
    end
  end

  defp nil_if_blank(nil), do: nil
  defp nil_if_blank(""), do: nil
  defp nil_if_blank(v), do: v
end
