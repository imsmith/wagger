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
  alias Wagger.Generator.Multi
  alias Wagger.Routes
  alias Wagger.Snapshots

  @providers ~w(aws azure caddy cloudflare coraza gcp nginx zap)

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
        active_nav: nil,
        editing_field: nil
      )

    {:ok, socket}
  end

  # -- App metadata editing events --

  @impl true
  def handle_event("toggle_app_field", %{"field" => "public"}, socket) do
    app = socket.assigns.app
    attrs = if app.public, do: %{public: false, shareable: false}, else: %{public: true}
    {:ok, app} = Applications.update_application(app, attrs)
    {:noreply, assign(socket, :app, app)}
  end

  def handle_event("toggle_app_field", %{"field" => "shareable"}, socket) do
    app = socket.assigns.app
    if app.public do
      {:ok, app} = Applications.update_application(app, %{shareable: !app.shareable})
      {:noreply, assign(socket, :app, app)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("edit_field", %{"field" => field}, socket)
      when field in ~w(description source) do
    {:noreply, assign(socket, :editing_field, field)}
  end

  @impl true
  def handle_event("save_field", %{"field" => field, "value" => value}, socket)
      when field in ~w(description source) do
    {:ok, app} = Applications.update_application(socket.assigns.app, %{field => value})
    {:noreply, socket |> assign(:app, app) |> assign(:editing_field, nil)}
  end

  @impl true
  def handle_event("cancel_field_edit", _params, socket) do
    {:noreply, assign(socket, :editing_field, nil)}
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

  @impl true
  def handle_event("delete_provider_config", %{"provider" => provider}, socket) do
    app = socket.assigns.app
    Snapshots.delete_snapshots_for_provider(app, provider)

    drifts = Map.new(@providers, fn p -> {p, Drift.detect(app, p)} end)
    snapshots = load_latest_snapshots(app)

    {:noreply,
     socket
     |> assign(:drifts, drifts)
     |> assign(:snapshots, snapshots)
     |> assign(:expanded_providers, MapSet.delete(socket.assigns.expanded_providers, provider))
     |> assign(:show_output, MapSet.delete(socket.assigns.show_output, provider))
     |> put_flash(:info, "#{String.capitalize(provider)} config deleted")}
  end

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
  def handle_event("quick_generate", %{"provider" => provider}, socket) do
    default_config = default_config_for(provider, socket.assigns.app.name)
    handle_event("regenerate", %{"provider" => provider, "config_override" => default_config}, socket)
  end

  @impl true
  def handle_event("regenerate", %{"provider" => provider} = params, socket) do
    app = socket.assigns.app
    routes = socket.assigns.routes
    provider_spec = Map.get(@provider_modules, provider)
    snapshot = Map.get(socket.assigns.snapshots, provider)

    raw_config =
      case params do
        %{"config_override" => override} when override != %{} -> override
        _ -> if snapshot, do: Jason.decode!(snapshot.config_params || "{}"), else: %{}
      end

    config = parse_provider_config(provider, raw_config)
    route_data = Drift.normalize_for_snapshot(routes)

    result =
      case provider_spec do
        specs when is_list(specs) -> Multi.generate(specs, route_data, config)
        module -> Generator.generate(module, route_data, config)
      end

    case result do
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

      {:error, %Comn.Errors.ErrorStruct{} = err} ->
        {:noreply, put_flash(socket, :error, "Generation failed: #{err.message}")}

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

  @doc "Splits a path into `{type, segment}` tuples, highlighting `{param}` placeholders."
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

  @doc "Returns the Tailwind background class for a method's treemap dot indicator."
  def method_dot_color("GET"), do: "bg-[var(--tn-method-get)]"
  def method_dot_color("POST"), do: "bg-[var(--tn-method-post)]"
  def method_dot_color("PUT"), do: "bg-[var(--tn-method-put)]"
  def method_dot_color("PATCH"), do: "bg-[var(--tn-method-put)]"
  def method_dot_color("DELETE"), do: "bg-[var(--tn-method-delete)]"
  def method_dot_color(_), do: "bg-[var(--tn-method-other)]"

  @doc "Returns a brief drift summary string for provider badges."
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
  defp default_config_for("zap", app_name), do: %{"prefix" => app_name, "target_url" => "{{TARGET_URL}}"}
  defp default_config_for("gcp", app_name) do
    %{
      "prefix" => app_name,
      "allow_ip_ranges" => "",
      "allow_regions" => "",
      "known_traffic_backend" => "",
      "deny_backend" => ""
    }
  end
  defp default_config_for(_provider, app_name), do: %{"prefix" => app_name}

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

  @doc "Returns providers that have never been generated for this app."
  def unconfigured_providers(drifts) do
    Enum.filter(@providers, fn provider ->
      drift = Map.get(drifts, provider)
      drift && drift.status == :never_generated
    end)
  end

  @doc "Returns the config field definitions for a provider."
  def config_fields_for(provider), do: Map.get(@provider_config_fields, provider, [])

  @doc "Returns the input type atom for a config field tuple (2-tuple defaults to :text)."
  def config_field_type({_key, _label, type}), do: type
  def config_field_type({_key, _label}), do: :text

  @doc "Returns the key and label from a config field tuple."
  def config_field_key_label({key, label, _type}), do: {key, label}
  def config_field_key_label({key, label}), do: {key, label}

  @doc """
  Splits a combined multi-artifact snapshot output into labeled sections.
  Delegates to `Wagger.Generator.Multi.split_artifacts/1`.
  Returns `[{label, filename, content}]`; for single-artifact outputs the list
  has one element with `label == nil`.
  """
  def split_snapshot_output(nil), do: [{nil, nil, ""}]
  def split_snapshot_output(output), do: Multi.split_artifacts(output)

  defp load_latest_snapshots(app) do
    Map.new(@providers, fn provider ->
      snap = Snapshots.latest_snapshot(app, provider)

      if snap do
        {provider, %{snap | output: Snapshots.decrypt_output(snap)}}
      else
        {provider, nil}
      end
    end)
  end

  def snapshot_config(snapshots, provider) do
    case Map.get(snapshots, provider) do
      nil -> %{}
      snap -> Jason.decode!(snap.config_params || "{}")
    end
  end
end
