defmodule WaggerWeb.ApplicationController do
  @moduledoc false

  use WaggerWeb, :controller

  alias Wagger.Applications

  action_fallback WaggerWeb.FallbackController

  def index(conn, params) do
    applications = Applications.list_applications(params)
    render(conn, :index, applications: applications)
  end

  def create(conn, params) do
    with {:ok, application} <- Applications.create_application(params) do
      conn
      |> put_status(:created)
      |> render(:show, application: application)
    end
  end

  def show(conn, %{"id" => id}) do
    try do
      application = Applications.get_application!(id)
      render(conn, :show, application: application)
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def update(conn, %{"id" => id} = params) do
    try do
      application = Applications.get_application!(id)

      with {:ok, updated} <- Applications.update_application(application, params) do
        render(conn, :show, application: updated)
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  def delete(conn, %{"id" => id}) do
    try do
      application = Applications.get_application!(id)

      with {:ok, _} <- Applications.delete_application(application) do
        send_resp(conn, :no_content, "")
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end
end
