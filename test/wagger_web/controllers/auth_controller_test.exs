defmodule WaggerWeb.AuthControllerTest do
  @moduledoc """
  Tests AuthController.callback by injecting a synthetic
  `Ueberauth.Auth` struct into conn.assigns, bypassing real OAuth.
  """

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Repo

  setup do
    Application.put_env(:wagger, :bootstrap_admin_email, "boot@admin.example")
    on_exit(fn -> Application.delete_env(:wagger, :bootstrap_admin_email) end)
    :ok
  end

  defp google_auth(email, uid, opts \\ []) do
    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email, name: "Test User"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{"email_verified" => Keyword.get(opts, :verified, true)}
      },
      credentials: %Ueberauth.Auth.Credentials{}
    }
  end

  defp inject_auth(conn, auth) do
    Plug.Conn.assign(conn, :ueberauth_auth, auth)
  end

  defp flash_error(conn) do
    Phoenix.Flash.get(conn.assigns.flash, :error)
  end

  describe "callback/2" do
    test "failure assigns redirect to /login with flash", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.assign(:ueberauth_failure, %Ueberauth.Failure{errors: []})
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/login"
      assert flash_error(conn) =~ "couldn't sign in"
    end

    test "unverified email rejects with flash", %{conn: conn} do
      auth = google_auth("u@u.com", "u-1", verified: false)

      conn =
        conn
        |> inject_auth(auth)
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/login"
      assert flash_error(conn) =~ "verified email"
    end

    test "existing identity logs the user in", %{conn: conn} do
      {:ok, user} = Accounts.register_oauth_user(%{email: "ret@x.com"})

      {:ok, _} =
        Accounts.link_identity(user, "google", %{provider_uid: "ret-1", email: "ret@x.com"})

      conn =
        conn
        |> inject_auth(google_auth("ret@x.com", "ret-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "matching email links new identity to existing user", %{conn: conn} do
      {:ok, user} = Accounts.register_oauth_user(%{email: "match@x.com"})

      conn =
        conn
        |> inject_auth(google_auth("match@x.com", "match-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert Accounts.find_user_by_identity("google", "match-1").id == user.id
    end

    test "bootstrap admin email creates admin user without invite", %{conn: conn} do
      conn =
        conn
        |> inject_auth(google_auth("boot@admin.example", "boot-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      user = Repo.get_by(Wagger.Accounts.User, email: "boot@admin.example")
      assert user.role == "admin"
      assert user.invite_code_id == nil
    end

    test "new email redirects to invite prompt with pending session", %{conn: conn} do
      conn =
        conn
        |> inject_auth(google_auth("new@x.com", "new-1"))
        |> get("/auth/google/callback")

      assert redirected_to(conn) == "/auth/invite"

      assert %{"provider" => "google", "email" => "new@x.com"} =
               get_session(conn, :pending_oauth)
    end
  end

  alias Wagger.Invites

  describe "invite_form/2" do
    test "redirects to /login when no pending OAuth in session", %{conn: conn} do
      conn = get(conn, ~p"/auth/invite")
      assert redirected_to(conn) == ~p"/login"
    end

    test "renders the form when pending OAuth is in session", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(
          pending_oauth: %{
            "provider" => "google",
            "provider_uid" => "x",
            "email" => "x@y.com",
            "display_name" => "X",
            "raw_info" => ""
          }
        )
        |> get(~p"/auth/invite")

      assert html_response(conn, 200) =~ "invite code"
    end
  end

  describe "invite_submit/2" do
    setup %{conn: conn} do
      conn =
        Plug.Test.init_test_session(conn,
          pending_oauth: %{
            "provider" => "google",
            "provider_uid" => "p-1",
            "email" => "p@p.com",
            "display_name" => "P",
            "raw_info" => ""
          }
        )

      {:ok, code} = Invites.create_code(%{label: "ok"})
      %{conn: conn, code: code}
    end

    test "valid code creates user, logs in, redirects to /", %{conn: conn, code: code} do
      conn = post(conn, ~p"/auth/invite", %{"code" => code.code})

      assert redirected_to(conn) == "/"
      assert is_integer(get_session(conn, :user_id))
      user = Wagger.Repo.get_by!(Wagger.Accounts.User, email: "p@p.com")
      assert user.invite_code_id == code.id
    end

    test "invalid code stays on page with flash", %{conn: conn} do
      conn = post(conn, ~p"/auth/invite", %{"code" => "bad-code"})
      assert html_response(conn, 200) =~ "invite code"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not recognized"
    end

    test "missing pending session redirects to /login", %{conn: _conn} do
      conn = post(build_conn(), ~p"/auth/invite", %{"code" => "anything"})
      assert redirected_to(conn) == ~p"/login"
    end
  end
end
