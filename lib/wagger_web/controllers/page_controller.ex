defmodule WaggerWeb.PageController do
  @moduledoc "Default page controller for non-LiveView HTML routes."

  use WaggerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
