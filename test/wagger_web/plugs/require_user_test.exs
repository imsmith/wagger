defmodule WaggerWeb.Plugs.RequireUserTest do
  @moduledoc false
  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.RequireUser

  test "passes when current_user is assigned" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "r@r.com"})

    conn =
      conn(:get, "/applications")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireUser.call([])

    refute conn.halted
  end

  test "redirects to /login and stashes return_to when no current_user" do
    conn =
      conn(:get, "/applications")
      |> init_test_session(%{})
      |> assign(:current_user, nil)
      |> RequireUser.call([])

    assert conn.halted
    assert conn.status == 302
    assert get_session(conn, :return_to) == "/applications"
  end
end
