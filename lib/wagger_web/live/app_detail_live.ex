defmodule WaggerWeb.AppDetailLive do
  @moduledoc """
  LiveView for the App Detail page.

  Displays application metadata, routes as a nested drill-down treemap,
  collapsible provider config sections with drift diffs, and an import area.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Generator
  alias Wagger.Routes
  alias Wagger.Snapshots

  @providers ~w(nginx aws cloudflare azure gcp caddy)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    app = Applications.get_application!(id)
    routes = Routes.list_routes(app)
    route_tree = build_route_tree(routes)

    drifts =
      Map.new(@providers, fn provider ->
        {provider, Drift.detect(app, provider)}
      end)

    expanded_providers =
      drifts
      |> Enum.filter(fn {_provider, drift} -> drift.status == :drifted end)
      |> Enum.map(fn {provider, _drift} -> provider end)
      |> MapSet.new()

    snapshots = load_latest_snapshots(app)

    socket =
      assign(socket,
        app: app,
        routes: routes,
        route_tree: route_tree,
        treemap_path: [],
        search_query: "",
        search_results: nil,
        drifts: drifts,
        expanded_providers: expanded_providers,
        snapshots: snapshots,
        show_output: MapSet.new(),
        show_import: false,
        all_providers: @providers,
        active_nav: nil
      )

    {:ok, socket}
  end

  # -- Treemap navigation events --

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
    results =
      if String.trim(query) == "" do
        nil
      else
        q = String.downcase(query)
        socket.assigns.routes
        |> Enum.filter(fn r ->
          String.contains?(String.downcase(r.path), q) or
            String.contains?(String.downcase(r.description || ""), q)
        end)
        |> Enum.flat_map(fn route ->
          Enum.map(route.methods, fn method ->
            %{method: method, path: route.path, path_parts: format_path(route.path),
              description: route.description, rate_limit: route.rate_limit}
          end)
        end)
      end

    {:noreply, assign(socket, search_query: query, search_results: results)}
  end

  # -- Provider events --

  @impl true
  def handle_event("toggle_provider", %{"provider" => provider}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_providers, provider),
        do: MapSet.delete(socket.assigns.expanded_providers, provider),
        else: MapSet.put(socket.assigns.expanded_providers, provider)

    {:noreply, assign(socket, :expanded_providers, expanded)}
  end

  @impl true
  def handle_event("toggle_import", _params, socket) do
    {:noreply, assign(socket, :show_import, !socket.assigns.show_import)}
  end

  @impl true
  def handle_event("toggle_output", %{"provider" => provider}, socket) do
    show = socket.assigns.show_output
    new_show = if MapSet.member?(show, provider), do: MapSet.delete(show, provider), else: MapSet.put(show, provider)
    {:noreply, assign(socket, :show_output, new_show)}
  end

  @provider_modules %{
    "nginx" => Wagger.Generator.Nginx,
    "aws" => Wagger.Generator.Aws,
    "cloudflare" => Wagger.Generator.Cloudflare,
    "azure" => Wagger.Generator.Azure,
    "gcp" => Wagger.Generator.Gcp,
    "caddy" => Wagger.Generator.Caddy
  }

  @provider_config_fields %{
    "nginx" => [{"prefix", "Name prefix"}, {"upstream", "Upstream URL"}],
    "caddy" => [{"prefix", "Name prefix"}, {"upstream", "Upstream URL"}],
    "aws" => [{"prefix", "Name prefix"}, {"scope", "REGIONAL or CLOUDFRONT"}],
    "cloudflare" => [{"prefix", "Name prefix"}],
    "azure" => [{"prefix", "Name prefix"}, {"mode", "Prevention or Detection"}],
    "gcp" => [{"prefix", "Name prefix"}]
  }

  @impl true
  def handle_event("quick_generate", %{"provider" => provider}, socket) do
    default_config = default_config_for(provider, socket.assigns.app.name)
    handle_event("regenerate", %{"provider" => provider, "config_override" => default_config}, socket)
  end

  @impl true
  def handle_event("regenerate", %{"provider" => provider} = params, socket) do
    app = socket.assigns.app
    routes = socket.assigns.routes
    module = Map.get(@provider_modules, provider)
    snapshot = Map.get(socket.assigns.snapshots, provider)

    config =
      case params do
        %{"config_override" => override} when override != %{} -> override
        _ -> if snapshot, do: Jason.decode!(snapshot.config_params || "{}"), else: %{}
      end

    route_data = Drift.normalize_for_snapshot(routes)

    case Generator.generate(module, route_data, config) do
      {:ok, output} ->
        checksum = Drift.compute_checksum(route_data)
        {:ok, _snap} = Snapshots.create_snapshot(%{
          application_id: app.id,
          provider: provider,
          config_params: Jason.encode!(config),
          route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
          output: output,
          checksum: checksum
        })

        drifts = Map.new(@providers, fn p -> {p, Drift.detect(app, p)} end)
        snapshots = load_latest_snapshots(app)

        {:noreply,
          socket
          |> assign(:drifts, drifts)
          |> assign(:snapshots, snapshots)
          |> assign(:expanded_providers, MapSet.put(socket.assigns.expanded_providers, provider))
          |> assign(:show_output, MapSet.put(socket.assigns.show_output, provider))
          |> put_flash(:info, "#{String.capitalize(provider)} config regenerated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Generation failed: #{inspect(reason)}")}
    end
  end

  # ---------------------------------------------------------------------------
  # Route tree building
  # ---------------------------------------------------------------------------

  @doc """
  Builds a nested tree from flat route paths.

  Returns a map of `%{segment => %{children: %{...}, routes: [route], count: N}}`.
  The tree can be traversed by following path segments. `count` is the total
  number of routes (leaf endpoints × methods) in this subtree.
  """
  def build_route_tree(routes) do
    Enum.reduce(routes, %{}, fn route, tree ->
      segments = String.split(route.path, "/", trim: true)
      insert_route(tree, segments, route)
    end)
    |> compute_counts()
  end

  defp insert_route(tree, [], route) do
    Map.update(tree, :_routes, [route], &[route | &1])
  end

  defp insert_route(tree, [segment | rest], route) do
    child = Map.get(tree, segment, %{})
    Map.put(tree, segment, insert_route(child, rest, route))
  end

  defp compute_counts(tree) when is_map(tree) do
    leaf_routes = Map.get(tree, :_routes, [])
    leaf_count = Enum.sum(Enum.map(leaf_routes, fn r -> length(r.methods) end))

    children =
      tree
      |> Map.drop([:_routes, :_count])
      |> Map.new(fn {k, v} -> {k, compute_counts(v)} end)

    child_count = children |> Map.values() |> Enum.reduce(0, fn c, acc -> acc + (c[:_count] || 0) end)

    children
    |> Map.put(:_routes, leaf_routes)
    |> Map.put(:_count, leaf_count + child_count)
  end

  @doc """
  Returns the subtree at the current treemap drill-down path.
  """
  def current_subtree(tree, []), do: tree

  def current_subtree(tree, [segment | rest]) do
    case Map.get(tree, segment) do
      nil -> %{_routes: [], _count: 0}
      child -> current_subtree(child, rest)
    end
  end

  @doc """
  Returns the children of a tree node as a sorted list of {segment, child_node} tuples.
  Excludes the :_routes and :_count metadata keys. Sorted by count descending.
  """
  def tree_children(node) do
    node
    |> Map.drop([:_routes, :_count])
    |> Enum.sort_by(fn {_seg, child} -> -(child[:_count] || 0) end)
  end

  @doc """
  Returns whether a tree node is a leaf (has no child segments, only routes).
  """
  def leaf_node?(node) do
    tree_children(node) == []
  end

  @doc """
  Returns all routes under a tree node, flattened and expanded into method rows.
  """
  def leaf_routes(node) do
    collect_routes(node)
    |> Enum.flat_map(fn route ->
      Enum.map(route.methods, fn method ->
        %{method: method, path: route.path, path_parts: format_path(route.path),
          description: route.description, rate_limit: route.rate_limit}
      end)
    end)
    |> Enum.sort_by(& &1.path)
  end

  defp collect_routes(node) when is_map(node) do
    own = Map.get(node, :_routes, [])
    child_routes =
      node
      |> Map.drop([:_routes, :_count])
      |> Map.values()
      |> Enum.flat_map(&collect_routes/1)

    own ++ child_routes
  end

  @doc """
  Determines the treemap cell color class based on the segment name and context.
  """
  def treemap_cell_class(_segment) do
    # Default: current/neutral color. Drift-aware coloring would need
    # per-route drift status which we can add later.
    "bg-base-300 border border-neutral hover:border-primary"
  end

  # ---------------------------------------------------------------------------
  # Path formatting
  # ---------------------------------------------------------------------------

  def format_path(path) when is_binary(path) do
    path
    |> String.split(~r/(\{[^}]+\})/, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "{"),
        do: {"param", segment},
        else: {"path", segment}
    end)
  end

  # ---------------------------------------------------------------------------
  # Provider helpers
  # ---------------------------------------------------------------------------

  def method_dot_color("GET"), do: "bg-[var(--tn-method-get)]"
  def method_dot_color("POST"), do: "bg-[var(--tn-method-post)]"
  def method_dot_color("PUT"), do: "bg-[var(--tn-method-put)]"
  def method_dot_color("PATCH"), do: "bg-[var(--tn-method-put)]"
  def method_dot_color("DELETE"), do: "bg-[var(--tn-method-delete)]"
  def method_dot_color(_), do: "bg-[var(--tn-method-other)]"

  def drift_summary(%Drift{status: :never_generated}), do: nil
  def drift_summary(%Drift{status: :current}), do: "current"
  def drift_summary(%Drift{status: :drifted, changes: changes}) do
    added = length(changes.added)
    removed = length(changes.removed)
    "+#{added} added, -#{removed} removed"
  end

  defp default_config_for(provider, app_name) when provider in ~w(nginx caddy) do
    %{"prefix" => app_name, "upstream" => "http://upstream:8080"}
  end
  defp default_config_for("aws", app_name), do: %{"prefix" => app_name, "scope" => "REGIONAL"}
  defp default_config_for("azure", app_name), do: %{"prefix" => app_name, "mode" => "Prevention"}
  defp default_config_for(_provider, app_name), do: %{"prefix" => app_name}

  def unconfigured_providers(drifts) do
    Enum.filter(@providers, fn provider ->
      drift = Map.get(drifts, provider)
      drift && drift.status == :never_generated
    end)
  end

  def config_fields_for(provider), do: Map.get(@provider_config_fields, provider, [])

  defp load_latest_snapshots(app) do
    Map.new(@providers, fn provider ->
      {provider, Snapshots.latest_snapshot(app, provider)}
    end)
  end

  def snapshot_config(snapshots, provider) do
    case Map.get(snapshots, provider) do
      nil -> %{}
      snap -> Jason.decode!(snap.config_params || "{}")
    end
  end
end
