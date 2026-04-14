defmodule WaggerWeb.AppDetailLive do
  @moduledoc """
  LiveView for the App Detail page.

  Displays application metadata, routes in a SwaggerUI-style grouped layout,
  collapsible provider config sections with drift diffs, and an import area.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes

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

    socket =
      assign(socket,
        app: app,
        routes: routes,
        grouped_routes: grouped_routes,
        drifts: drifts,
        expanded_providers: expanded_providers,
        show_import: false,
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
