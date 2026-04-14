defmodule WaggerWeb.HubListLive do
  @moduledoc """
  LiveView for the public Hub listing page.

  Displays all shareable applications. No authentication required.
  """

  use WaggerWeb, :live_view

  alias Wagger.Applications
  alias Wagger.Routes

  @impl true
  def mount(_params, _session, socket) do
    apps =
      Applications.list_shareable_applications()
      |> Enum.map(fn app ->
        count = app |> Routes.list_routes() |> length()
        %{app: app, route_count: count}
      end)

    {:ok,
     socket
     |> assign(:apps, apps)
     |> assign(:active_nav, :hub)
     |> assign(:page_title, "Hub")}
  end
end
