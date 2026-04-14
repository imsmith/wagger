defmodule WaggerWeb.RouteController do
  @moduledoc false

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Routes

  action_fallback WaggerWeb.FallbackController

  def index(conn, %{"application_id" => app_id} = params) do
    try do
      app = Applications.get_application!(app_id)
      routes = Routes.list_routes(app, params)
      render(conn, :index, routes: routes)
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def create(conn, %{"application_id" => app_id} = params) do
    try do
      app = Applications.get_application!(app_id)

      with {:ok, route} <- Routes.create_route(app, params) do
        conn
        |> put_status(:created)
        |> render(:show, route: route)
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def show(conn, %{"application_id" => app_id, "id" => id}) do
    try do
      app = Applications.get_application!(app_id)
      route = Routes.get_route!(app, id)
      render(conn, :show, route: route)
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def update(conn, %{"application_id" => app_id, "id" => id} = params) do
    try do
      app = Applications.get_application!(app_id)
      route = Routes.get_route!(app, id)

      with {:ok, updated} <- Routes.update_route(route, params) do
        render(conn, :show, route: updated)
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def delete(conn, %{"application_id" => app_id, "id" => id}) do
    try do
      app = Applications.get_application!(app_id)
      route = Routes.get_route!(app, id)

      with {:ok, _} <- Routes.delete_route(route) do
        send_resp(conn, :no_content, "")
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end
end
