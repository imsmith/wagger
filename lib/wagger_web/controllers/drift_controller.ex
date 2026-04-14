defmodule WaggerWeb.DriftController do
  @moduledoc """
  Controller for checking drift status between current application routes
  and the most recently generated WAF config snapshot.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Drift

  action_fallback WaggerWeb.FallbackController

  def show(conn, %{"application_id" => app_id, "provider" => provider}) do
    app = Applications.get_application!(app_id)
    result = Drift.detect(app, provider)
    render(conn, :show, drift: result)
  end
end
