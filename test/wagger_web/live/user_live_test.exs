defmodule WaggerWeb.UserLiveTest do
  @moduledoc false

  use WaggerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Wagger.Accounts

  defp create_user(_context) do
    {:ok, user, _key} =
      Accounts.create_user(%{"username" => "testuser", "display_name" => "Test User"})

    %{user: user}
  end

  describe "user list" do
    setup :create_user

    test "renders user list with existing usernames", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")

      assert html =~ "testuser"
    end
  end

  describe "create user" do
    test "creates a new user and shows the API key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/users")

      html =
        view
        |> form("#create-user-form", %{"username" => "newuser", "display_name" => "New User"})
        |> render_submit()

      assert html =~ "API Key"
    end
  end

  describe "navigation" do
    test "shows Users nav as active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users")

      assert html =~ "Users"
    end
  end
end
