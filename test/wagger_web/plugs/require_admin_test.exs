defmodule WaggerWeb.Plugs.RequireAdminTest do
  @moduledoc false
  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.RequireAdmin

  test "passes when current_user is admin" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "a@a.com", role: "admin"})

    conn =
      conn(:get, "/admin/invites")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireAdmin.call([])

    refute conn.halted
  end

  test "renders 403 when current_user is not admin" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "u@u.com"})

    conn =
      conn(:get, "/admin/invites")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireAdmin.call([])

    assert conn.halted
    assert conn.status == 403
  end
end
