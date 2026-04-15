defmodule WaggerWeb.DashboardLive do
  @moduledoc """
  LiveView for the main dashboard.

  Shows a status summary bar (drifted / current / never_generated counts) across all
  app-provider pairs. Clicking a status card filters to show the app cards in that state.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Import
  alias Wagger.Routes

  @providers ~w(aws azure caddy cloudflare coraza gcp nginx zap)

  @impl true
  def mount(_params, _session, socket) do
    apps = Applications.list_applications()
    drift_data = build_drift_data(apps)

    {:ok,
     socket
     |> assign(
       apps: apps,
       drift_data: drift_data,
       status_filter: nil,
       show_new_app: false,
       new_app_name: "",
       new_app_import_mode: "openapi",
       new_app_input: "",
       new_app_preview: nil,
       loading: nil,
       page_title: "Dashboard",
       active_nav: :dashboard
     )
     |> allow_upload(:spec_file,
       accept: ~w(.json .txt),
       max_entries: 1,
       max_file_size: 10_000_000,
       auto_upload: true
     )}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status_str}, socket) do
    status = String.to_existing_atom(status_str)

    new_filter =
      if socket.assigns.status_filter == status, do: nil, else: status

    {:noreply, assign(socket, status_filter: new_filter)}
  end

  @impl true
  def handle_event("toggle_new_app", _, socket) do
    {:noreply, assign(socket, :show_new_app, !socket.assigns.show_new_app)}
  end

  @impl true
  def handle_event("new_app_mode", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, new_app_import_mode: mode, new_app_input: "", new_app_preview: nil)}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("preview_new_app", params, socket) do
    {input, socket} =
      case consume_uploaded_entries(socket, :spec_file, fn %{path: path}, _entry ->
        {:ok, File.read!(path)}
      end) do
        [content | _] -> {content, socket}
        [] -> {params["input"] || "", socket}
      end

    if String.trim(input) == "" do
      {:noreply, put_flash(socket, :error, "No input provided — paste data, drop a file, or browse")}
    else
      name = params["name"] || ""
      socket = assign(socket, :loading, :preview)
      send(self(), {:do_preview, input, name})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("create_new_app", %{"name" => name}, socket) do
    preview = socket.assigns.new_app_preview

    if is_nil(preview) or name == "" do
      {:noreply, put_flash(socket, :error, "Provide an app name and import data")}
    else
      socket = assign(socket, :loading, :creating)
      send(self(), {:do_create_app, name, preview})
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:do_preview, input, name}, socket) do
    socket = do_preview(input, name, socket)
    {:noreply, assign(socket, :loading, nil)}
  end

  @impl true
  def handle_info({:do_create_app, name, preview}, socket) do
    case Applications.create_application(%{name: name}) do
      {:ok, app} ->
        for route_map <- preview.parsed do
          attrs = Map.take(route_map, [:path, :methods, :path_type, :description, :query_params, :headers, :rate_limit, :tags])
          Routes.create_route(app, attrs)
        end

        apps = Applications.list_applications()
        drift_data = build_drift_data(apps)

        {:noreply,
          socket
          |> assign(apps: apps, drift_data: drift_data, loading: nil,
                    show_new_app: false, new_app_preview: nil,
                    new_app_name: "", new_app_input: "")
          |> put_flash(:info, "Created #{name} with #{length(preview.parsed)} routes")
          |> push_navigate(to: ~p"/applications/#{app.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg = changeset.errors |> Enum.map(fn {k, {v, _}} -> "#{k} #{v}" end) |> Enum.join(", ")
        {:noreply, socket |> assign(:loading, nil) |> put_flash(:error, msg)}

      {:error, %Comn.Errors.ErrorStruct{} = err} ->
        {:noreply, socket |> assign(:loading, nil) |> put_flash(:error, err.message)}
    end
  end

  defp do_preview(input, name, socket) do
    mode = socket.assigns.new_app_import_mode

    {parsed, skipped, suggested_name} =
      case mode do
        "openapi" ->
          case Jason.decode(input) do
            {:ok, spec} ->
              {routes, errors} = Import.OpenApi.parse(spec)
              title = get_in(spec, ["info", "title"]) || ""
              suggested = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
              {routes, errors, suggested}
            {:error, %Jason.DecodeError{} = err} ->
              {[], ["Invalid JSON: #{Exception.message(err)}"], ""}
            {:error, _} ->
              {[], ["Invalid JSON"], ""}
          end
        "bulk" ->
          {routes, skipped} = Import.Bulk.parse(input)
          {routes, skipped, ""}
        "accesslog" ->
          {routes, skipped} = Import.AccessLog.parse(input)
          {routes, skipped, ""}
      end

    app_name = if name == "" and suggested_name != "", do: suggested_name, else: name

    socket =
      cond do
        parsed == [] and skipped == [] ->
          put_flash(socket, :error, "No routes found in input")

        parsed == [] ->
          put_flash(socket, :error, "No valid routes found — #{length(skipped)} lines skipped")

        true ->
          socket
      end

    assign(socket,
      new_app_name: app_name,
      new_app_input: input,
      new_app_preview: %{parsed: parsed, skipped: skipped}
    )
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

  @doc "Returns placeholder text for the import textarea based on the selected mode."
  def input_placeholder("openapi"), do: "Paste OpenAPI 3.x JSON spec..."
  def input_placeholder("bulk"), do: "GET /api/users\nGET,POST /api/items - Item CRUD\n/health"
  def input_placeholder("accesslog"), do: "Paste nginx/apache/caddy access log lines..."

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
