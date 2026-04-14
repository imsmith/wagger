defmodule WaggerWeb.Plugs.AuthenticateTest do
  @moduledoc """
  Tests for the WaggerWeb.Plugs.Authenticate plug.

  Covers valid Bearer token authentication, invalid token rejection,
  missing authorization header rejection, and setup mode bypass.
  """

  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.Authenticate

  setup do
    {:ok, user, api_key} = Accounts.create_user(%{"username" => "testuser"})
    %{user: user, api_key: api_key}
  end

  test "authenticates valid Bearer token and assigns current_user", %{user: user, api_key: api_key} do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> Authenticate.call(Authenticate.init([]))

    refute conn.halted
    assert conn.assigns[:current_user].id == user.id
  end

  test "rejects invalid Bearer token with 401", %{} do
    conn =
      conn(:get, "/api/applications")
      |> put_req_header("authorization", "Bearer invalidtoken")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects missing authorization header with 401", %{} do
    conn =
      conn(:get, "/api/applications")
      |> Authenticate.call(Authenticate.init([]))

    assert conn.halted
    assert conn.status == 401
  end

  test "allows unauthenticated access in setup mode when no users exist" do
    # Delete the user created in setup so the DB is empty
    Wagger.Repo.delete_all(Wagger.Accounts.User)

    conn =
      conn(:get, "/api/setup")
      |> Authenticate.call(Authenticate.init(allow_setup: true))

    refute conn.halted
    assert conn.assigns[:setup_mode] == true
  end
end
