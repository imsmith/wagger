defmodule WaggerWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts with a 403 plain-text response when `:current_user` is not an
  admin. Assumes RequireUser has already run; if `current_user` is nil
  we still emit 403 (don't redirect — admin pages shouldn't bounce
  logged-in non-admins).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{role: "admin"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden")
    |> halt()
  end
end
