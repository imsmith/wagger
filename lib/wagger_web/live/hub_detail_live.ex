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
      method_dot_color: 1
    ]

  @providers ~w(aws azure caddy cloudflare coraza gcp nginx zap)

  @provider_modules %{
    "nginx" => Wagger.Generator.Nginx,
    "aws" => Wagger.Generator.Aws,
    "cloudflare" => Wagger.Generator.Cloudflare,
    "azure" => Wagger.Generator.Azure,
    "gcp" => Wagger.Generator.Gcp,
    "caddy" => Wagger.Generator.Caddy,
    "coraza" => Wagger.Generator.Coraza,
    "zap" => Wagger.Generator.Zap
  }

  @provider_config_fields %{
    "nginx" => [{"prefix", "Name prefix"}, {"upstream", "Upstream URL"}],
    "caddy" => [{"prefix", "Name prefix"}, {"upstream", "Upstream URL"}],
    "aws" => [{"prefix", "Name prefix"}, {"scope", "REGIONAL or CLOUDFRONT"}],
    "cloudflare" => [{"prefix", "Name prefix"}],
    "azure" => [{"prefix", "Name prefix"}, {"mode", "Prevention or Detection"}],
    "gcp" => [{"prefix", "Name prefix"}],
    "coraza" => [{"prefix", "Name prefix"}, {"start_rule_id", "Starting rule ID (default 100001)"}],
    "zap" => [{"prefix", "Name prefix"}, {"target_url", "Target URL (or {{TARGET_URL}})"}]
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
    module = Map.fetch!(@provider_modules, provider)
    routes = socket.assigns.routes
    route_data = Drift.normalize_for_snapshot(routes)

    config = Map.drop(params, ["_target"])

    case Generator.generate(module, route_data, config) do
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
end
