defmodule WaggerWeb.AppDetailLive do
  @moduledoc """
  LiveView for the App Detail page.

  Displays application metadata, routes in a SwaggerUI-style grouped layout,
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
    grouped_routes = group_routes(routes)

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
    show_output = MapSet.new()

    socket =
      assign(socket,
        app: app,
        routes: routes,
        grouped_routes: grouped_routes,
        drifts: drifts,
        expanded_providers: expanded_providers,
        snapshots: snapshots,
        show_output: show_output,
        show_import: false,
        show_new_provider: false,
        selected_new_provider: nil,
        active_nav: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_provider", %{"provider" => provider}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_providers, provider) do
        MapSet.delete(socket.assigns.expanded_providers, provider)
      else
        MapSet.put(socket.assigns.expanded_providers, provider)
      end

    {:noreply, assign(socket, :expanded_providers, expanded)}
  end

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
  def handle_event("toggle_new_provider", _, socket) do
    {:noreply, assign(socket, :show_new_provider, !socket.assigns[:show_new_provider])}
  end

  @impl true
  def handle_event("select_new_provider", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, :selected_new_provider, provider)}
  end

  @impl true
  def handle_event("generate_new", params, socket) do
    provider = params["provider"]
    config = Map.drop(params, ["provider", "_target"])

    if provider == "" or is_nil(Map.get(@provider_modules, provider)) do
      {:noreply, put_flash(socket, :error, "Select a provider")}
    else
      # Delegate to the same regenerate logic
      socket = assign(socket, :snapshots, Map.put(socket.assigns.snapshots, provider, nil))
      handle_event("regenerate", %{"provider" => provider, "config_override" => config}, socket)
    end
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

        # Reload state
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

  @doc """
  Groups route+method combinations by common prefix (first two path segments).

  Each route with N methods becomes N separate rows. Groups are keyed by the
  first two path segments, e.g. "/api/users" covers both "/api/users" and
  "/api/users/{id}". Routes without two segments go under "other".

  Returns a list of `{group_key, [row]}` tuples sorted by group key, where each
  row is a map with keys: `:method`, `:path`, `:path_parts`, `:description`,
  `:rate_limit`, `:tags`.
  """
  def group_routes(routes) do
    rows =
      Enum.flat_map(routes, fn route ->
        Enum.map(route.methods, fn method ->
          %{
            method: method,
            path: route.path,
            path_parts: format_path(route.path),
            description: route.description,
            rate_limit: route.rate_limit,
            tags: route.tags
          }
        end)
      end)

    rows
    |> Enum.group_by(fn row -> route_group_key(row.path) end)
    |> Enum.sort_by(fn {key, _} -> key end)
  end

  @doc """
  Splits a path on `{param}` boundaries into a list of `{type, segment}` tuples.

  Static path segments become `{"path", text}` tuples; parameter segments
  become `{"param", text}` tuples.

  ## Examples

      iex> format_path("/api/users/{id}")
      [{"path", "/api/users/"}, {"param", "{id}"}]

      iex> format_path("/health")
      [{"path", "/health"}]
  """
  def format_path(path) when is_binary(path) do
    path
    |> String.split(~r/(\{[^}]+\})/, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn segment ->
      if String.starts_with?(segment, "{") do
        {"param", segment}
      else
        {"path", segment}
      end
    end)
  end

  @doc """
  Returns a brief drift summary string for display in provider badges.

  - `:drifted` — returns "+N added, -N removed"
  - `:current` — returns "current"
  - `:never_generated` — returns nil
  """
  def drift_summary(%Drift{status: :never_generated}), do: nil

  def drift_summary(%Drift{status: :current}), do: "current"

  def drift_summary(%Drift{status: :drifted, changes: changes}) do
    added = length(changes.added)
    removed = length(changes.removed)
    "+#{added} added, -#{removed} removed"
  end

  def unconfigured_providers(drifts) do
    Enum.filter(@providers, fn provider ->
      drift = Map.get(drifts, provider)
      drift && drift.status == :never_generated
    end)
  end

  def config_fields_for(provider) do
    Map.get(@provider_config_fields, provider, [])
  end

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

  # Returns the group key for a route path: first two non-empty segments joined,
  # or "other" if fewer than two segments exist.
  defp route_group_key(path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.take(2)

    case segments do
      [a, b] -> "/#{a}/#{b}"
      [a] -> "/#{a}"
      [] -> "other"
    end
  end

end
