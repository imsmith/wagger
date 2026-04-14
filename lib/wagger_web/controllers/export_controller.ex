defmodule WaggerWeb.ExportController do
  @moduledoc """
  Controller for exporting application routes in EDN format.

  Provides a single `show` action that serializes all routes for a given
  application as an EDN document and returns it with the `application/edn`
  content type.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Export

  def show(conn, %{"application_id" => app_id}) do
    app = Applications.get_application!(app_id)
    {:ok, edn} = Export.to_edn(app)

    conn
    |> put_resp_content_type("application/edn")
    |> send_resp(200, edn)
  end
end
