defmodule WaggerWeb.SnapshotController do
  @moduledoc """
  Controller for listing and viewing generation snapshots scoped to an application.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Snapshots

  action_fallback WaggerWeb.FallbackController

  def index(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)
    snapshots = Snapshots.list_snapshots(app, params)
    render(conn, :index, snapshots: snapshots)
  end

  def show(conn, %{"application_id" => app_id, "id" => id}) do
    try do
      app = Applications.get_application!(app_id)
      snapshot = Snapshots.get_snapshot!(app, id)
      render(conn, :show, snapshot: snapshot)
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end
end
