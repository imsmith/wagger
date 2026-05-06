defmodule WaggerWeb.AccountLiveTest do
  @moduledoc false
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.Accounts

  setup %{conn: conn} do
    {:ok, user} = Accounts.register_oauth_user(%{email: "me@me.com"})
    {:ok, _} = Accounts.link_identity(user, "google", %{provider_uid: "g-1", email: "me@me.com"})
    conn = log_in_as(conn, user)
    %{conn: conn, user: user}
  end

  test "lists linked identities", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/account")
    assert html =~ "google"
  end

  test "set password persists a hashed password", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> form("#password-form", password: %{value: "long-enough-password"})
    |> render_submit()

    reloaded = Wagger.Repo.get!(Wagger.Accounts.User, user.id)
    refute is_nil(reloaded.password_hash)
  end

  test "unlink identity refuses if it would orphan the account", %{conn: conn, user: user} do
    identity = Wagger.Repo.get_by!(Wagger.Accounts.OauthIdentity, user_id: user.id)

    {:ok, view, _html} = live(conn, ~p"/account")
    html =
      view
      |> element(~s|button[phx-click="unlink"][phx-value-id="#{identity.id}"]|)
      |> render_click()

    assert html =~ "no way to log in"
  end

  test "unlink identity succeeds when password is also set", %{conn: conn, user: user} do
    {:ok, _} = Accounts.set_password(user, "long-enough-password")

    identity = Wagger.Repo.get_by!(Wagger.Accounts.OauthIdentity, user_id: user.id)

    {:ok, view, _html} = live(conn, ~p"/account")
    view
    |> element(~s|button[phx-click="unlink"][phx-value-id="#{identity.id}"]|)
    |> render_click()

    assert is_nil(Wagger.Repo.get(Wagger.Accounts.OauthIdentity, identity.id))
  end
end
