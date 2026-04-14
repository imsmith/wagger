defmodule WaggerWeb.AppListLive do
  @moduledoc """
  LiveView for the Applications listing page.

  Displays all applications in a table with name, description, route count,
  tags, and creation date. Links through to the app detail page.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Routes

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:apps, load_apps())
     |> assign(:editing_description, nil)
     |> assign(:active_nav, :applications)
     |> assign(:page_title, "Applications")}
  end

  @impl true
  def handle_event("toggle", %{"id" => id, "field" => "public"}, socket) do
    app = Applications.get_application!(id)
    attrs = if app.public, do: %{public: false, shareable: false}, else: %{public: true}
    {:ok, _} = Applications.update_application(app, attrs)
    {:noreply, assign(socket, :apps, load_apps())}
  end

  def handle_event("toggle", %{"id" => id, "field" => "shareable"}, socket) do
    app = Applications.get_application!(id)
    if app.public do
      {:ok, _} = Applications.update_application(app, %{shareable: !app.shareable})
      {:noreply, assign(socket, :apps, load_apps())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("edit_description", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing_description, String.to_integer(id))}
  end

  @impl true
  def handle_event("save_description", %{"app_id" => id, "description" => desc}, socket) do
    app = Applications.get_application!(String.to_integer(id))
    {:ok, _} = Applications.update_application(app, %{description: desc})
    {:noreply, socket |> assign(:editing_description, nil) |> assign(:apps, load_apps())}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_description, nil)}
  end

  defp load_apps do
    Applications.list_applications()
    |> Enum.map(fn app ->
      count = app |> Routes.list_routes() |> length()
      %{app: app, route_count: count}
    end)
  end
end
