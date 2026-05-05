defmodule WaggerWeb.SessionController do
  @moduledoc """
  Renders the login page and handles password-based sign-in and sign-out.
  Filled out across multiple tasks.
  """

  use WaggerWeb, :controller

  def new(conn, _params) do
    text(conn, "login page placeholder")
  end

  def delete(conn, _params) do
    conn |> clear_session() |> redirect(to: "/")
  end
end
