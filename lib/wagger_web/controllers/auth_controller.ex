defmodule WaggerWeb.AuthController do
  @moduledoc """
  Handles OAuth login flows (request, callback) and post-OAuth invite-code
  redemption.
  """

  use WaggerWeb, :controller

  plug Ueberauth

  def request(conn, _params) do
    # Ueberauth's plug above intercepts and redirects to the provider.
    # If we get here, the provider is unknown.
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(conn, _params) do
    # Filled in by later tasks.
    conn
    |> put_flash(:error, "Authentication not yet implemented.")
    |> redirect(to: ~p"/login")
  end
end
