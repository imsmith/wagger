defmodule WaggerWeb.LookupController do
  @moduledoc """
  Controller for per-request route lookup.

  Given an HTTP method and a request path, determines which declared route(s)
  match and whether the method is allowed by the route policy.

  GET /api/applications/:application_id/lookup?method=GET&path=/api/users/123

  Returns 200 always when the lookup itself succeeds — verdict :not_in_allowlist
  is data, not an HTTP error.  Returns 400 when required query params are
  absent.  Returns 404 when the application_id is unknown.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Routes

  def show(conn, %{"application_id" => app_id, "method" => method, "path" => path})
      when method != "" and path != "" do
    app = Applications.get_application!(app_id)
    result = Routes.lookup_for_request(app, method, path)
    json(conn, serialize(result))
  end

  def show(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required query parameters: method, path"})
  end

  # Rescue Ecto.NoResultsError to return a clean 404 JSON response.
  def action(conn, opts) do
    try do
      super(conn, opts)
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Application not found"})
    end
  end

  defp serialize(%{verdict: verdict, method: method, path: path, matches: matches}) do
    %{
      verdict: verdict,
      method: method,
      path: path,
      matches: Enum.map(matches, &serialize_match/1)
    }
  end

  defp serialize_match(m) do
    %{
      route_id: m.route_id,
      path: m.path,
      path_type: m.path_type,
      methods: m.methods,
      method_allowed: m.method_allowed,
      rate_limit: m.rate_limit,
      description: m.description
    }
  end
end
