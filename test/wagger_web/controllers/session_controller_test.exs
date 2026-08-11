defmodule WaggerWeb.SessionControllerTest do
  @moduledoc false
  use WaggerWeb.ConnCase

  alias Wagger.Accounts

  describe "new/2" do
    test "renders login page", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Sign in"
    end

    test "the password field can be revealed", %{conn: conn} do
      html = conn |> get(~p"/login") |> html_response(200)

      assert html =~ ~s(id="password-toggle")
      assert html =~ ~s(aria-controls="password-field")
    end
  end

  describe "create/2" do
    setup do
      {:ok, user} = Accounts.register_oauth_user(%{email: "p@p.com"})
      {:ok, user} = Accounts.set_password(user, "long-enough-pass")
      %{user: user}
    end

    test "valid credentials log in and redirect", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", %{"email" => "p@p.com", "password" => "long-enough-pass"})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "invalid credentials stay on login page with flash", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"email" => "p@p.com", "password" => "wrong"})
      assert html_response(conn, 200) =~ "Sign in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "incorrect"
    end

    test "unknown user stays on login page (no info leak)", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"email" => "ghost@x.com", "password" => "anything-long"})
      assert html_response(conn, 200) =~ "Sign in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "incorrect"
    end
  end

  describe "delete/2" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(user_id: 123)
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert is_nil(get_session(conn, :user_id))
    end
  end
end
