defmodule WaggerWeb.Plugs.RequireUser do
  @moduledoc """
  Halts the request with a redirect to /login when no `:current_user` is
  assigned. Stashes the requested path in session under `:return_to` so
  the post-login flow can return there.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3, fetch_flash: 2]

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    return_to =
      conn.request_path <> if conn.query_string == "", do: "", else: "?" <> conn.query_string

    conn
    |> fetch_flash([])
    |> put_session(:return_to, return_to)
    |> put_flash(:error, "You need to sign in to access that.")
    |> redirect(to: "/login")
    |> halt()
  end
end
