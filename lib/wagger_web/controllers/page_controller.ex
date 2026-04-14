defmodule WaggerWeb.PageController do
  use WaggerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
