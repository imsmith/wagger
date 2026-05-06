defmodule WaggerWeb.Plugs.FetchCurrentUserTest do
  @moduledoc false
  use Wagger.DataCase

  import Plug.Test

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.FetchCurrentUser

  test "assigns nil when no user_id in session" do
    conn = conn(:get, "/") |> init_test_session(%{}) |> FetchCurrentUser.call([])
    assert is_nil(conn.assigns[:current_user])
  end

  test "assigns the user when user_id is in session" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "fc@x.com"})

    conn =
      conn(:get, "/")
      |> init_test_session(%{"user_id" => user.id})
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user.id == user.id
  end

  test "assigns nil when session has stale user_id" do
    conn =
      conn(:get, "/")
      |> init_test_session(%{"user_id" => 999_999})
      |> FetchCurrentUser.call([])

    assert is_nil(conn.assigns[:current_user])
  end
end
