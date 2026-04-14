defmodule WaggerWeb.DashboardLive do
  @moduledoc """
  LiveView for the main dashboard.

  Shows a status summary bar (drifted / current / never_generated counts) across all
  app-provider pairs. Clicking a status card filters to show the app cards in that state.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Routes

  @providers ~w(nginx aws cloudflare azure gcp caddy)

  @impl true
  def mount(_params, _session, socket) do
    apps = Applications.list_applications()
    drift_data = build_drift_data(apps)

    {:ok,
     assign(socket,
       apps: apps,
       drift_data: drift_data,
       status_filter: nil,
       page_title: "Dashboard",
       active_nav: :dashboard
     )}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status_str}, socket) do
    status = String.to_existing_atom(status_str)

    new_filter =
      if socket.assigns.status_filter == status, do: nil, else: status

    {:noreply, assign(socket, status_filter: new_filter)}
  end

  # ---------------------------------------------------------------------------
  # Helpers (public so templates can call them directly)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a map of status counts across all app-provider pairs.

      %{drifted: N, current: N, never_generated: N}
  """
  def status_counts(drift_data) do
    Enum.reduce(drift_data, %{drifted: 0, current: 0, never_generated: 0}, fn {_app_id, providers}, acc ->
      Enum.reduce(providers, acc, fn {_provider, drift}, inner ->
        Map.update!(inner, drift.status, &(&1 + 1))
      end)
    end)
  end

  @doc """
  Returns the list of apps that have at least one provider in `status_filter`,
  sorted by number of providers in that status (descending).

  Returns all apps (unsorted) when `status_filter` is nil.
  """
  def filtered_apps(_apps, _drift_data, nil), do: []

  def filtered_apps(apps, drift_data, status_filter) do
    apps
    |> Enum.filter(fn app ->
      drift_data
      |> Map.get(app.id, %{})
      |> Enum.any?(fn {_provider, drift} -> drift.status == status_filter end)
    end)
    |> Enum.sort_by(
      fn app ->
        drift_data
        |> Map.get(app.id, %{})
        |> Enum.count(fn {_provider, drift} -> drift.status == status_filter end)
      end,
      :desc
    )
  end

  @doc """
  Returns the provider drift map for a single app.
  """
  def app_provider_drifts(drift_data, app_id) do
    Map.get(drift_data, app_id, %{})
  end

  @doc """
  Returns a short summary string for a drift struct, e.g. "+2 added", "current", or nil.
  """
  def drift_summary(%Drift{status: :current}), do: "current"
  def drift_summary(%Drift{status: :never_generated}), do: nil

  def drift_summary(%Drift{status: :drifted, changes: changes}) do
    parts =
      [
        changes.added != [] && "+#{length(changes.added)} added",
        changes.removed != [] && "-#{length(changes.removed)} removed",
        changes.modified != [] && "~#{length(changes.modified)} changed"
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> "drifted"
      _ -> Enum.join(parts, " ")
    end
  end

  @doc """
  Returns the Tailwind left-border class for an app card based on the worst
  provider status present in the given provider drift map.
  """
  def app_card_border_class(provider_drifts) do
    statuses =
      provider_drifts
      |> Map.values()
      |> Enum.map(& &1.status)

    cond do
      Enum.any?(provider_drifts, fn {_p, d} ->
        d.status == :drifted and d.changes.removed != []
      end) ->
        "border-l-4 border-l-error"

      :drifted in statuses ->
        "border-l-4 border-l-warning"

      true ->
        "border-l-4 border-l-neutral"
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_drift_data(apps) do
    Map.new(apps, fn app ->
      provider_drifts =
        Map.new(@providers, fn provider ->
          {provider, Drift.detect(app, provider)}
        end)

      {app.id, provider_drifts}
    end)
  end

  defp route_count(app) do
    app |> Routes.list_routes() |> length()
  end
end
