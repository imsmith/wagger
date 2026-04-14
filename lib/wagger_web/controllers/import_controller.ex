defmodule WaggerWeb.ImportController do
  @moduledoc """
  Controller for importing routes into an application via bulk text, OpenAPI
  spec, or access log. All actions return a preview struct that includes an
  HMAC token; the confirm action verifies the token before inserting routes.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Import.AccessLog
  alias Wagger.Import.Bulk
  alias Wagger.Import.OpenApi
  alias Wagger.Import.Preview

  action_fallback WaggerWeb.FallbackController

  def bulk(conn, %{"application_id" => app_id, "body" => body}) do
    app = Applications.get_application!(app_id)
    {routes, skipped} = Bulk.parse(body)
    preview = Preview.build(app, routes, skipped)
    render(conn, :preview, preview: preview)
  end

  def openapi(conn, %{"application_id" => app_id, "spec" => spec}) do
    app = Applications.get_application!(app_id)
    {routes, errors} = OpenApi.parse(spec)
    preview = Preview.build(app, routes, errors)
    render(conn, :preview, preview: preview)
  end

  def accesslog(conn, %{"application_id" => app_id, "body" => body}) do
    app = Applications.get_application!(app_id)
    {routes, skipped} = AccessLog.parse(body)
    preview = Preview.build(app, routes, skipped)
    render(conn, :preview, preview: preview)
  end

  def confirm(conn, %{"application_id" => app_id} = params) do
    app = Applications.get_application!(app_id)
    parsed_raw = Map.get(params, "parsed", [])
    token = Map.get(params, "preview_token", "")

    parsed = atomize_parsed(parsed_raw)

    if Preview.verify_token(parsed, token) do
      preview = %Preview{
        parsed: parsed,
        conflicts: [],
        skipped: [],
        preview_token: token
      }

      {:ok, inserted} = Preview.confirm(app, preview)

      conn
      |> put_status(:created)
      |> render(:confirm, inserted: inserted)
    else
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: "Invalid preview token — routes may have been tampered with"})
    end
  end

  defp atomize_parsed(routes) do
    Enum.map(routes, fn route ->
      %{
        path: route["path"],
        methods: route["methods"],
        path_type: route["path_type"],
        description: route["description"]
      }
    end)
  end
end
