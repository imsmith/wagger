defmodule WaggerWeb.InviteCodeLiveTest do
  @moduledoc false
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.Invites

  describe "as admin" do
    setup %{conn: conn} do
      conn = log_in_as_admin(conn)
      %{conn: conn}
    end

    test "lists existing codes", %{conn: conn} do
      {:ok, _} = Invites.create_code(%{label: "test-1"})

      {:ok, _view, html} = live(conn, ~p"/admin/invites")
      assert html =~ "test-1"
    end

    test "creates a new code via form submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/invites")

      view
      |> form("#new-code-form", invite: %{label: "fresh"})
      |> render_submit()

      assert render(view) =~ "fresh"
    end

    test "revoke action revokes the code", %{conn: conn} do
      {:ok, code} = Invites.create_code(%{label: "rev"})

      {:ok, view, _html} = live(conn, ~p"/admin/invites")
      view |> element(~s|button[phx-click="revoke"][phx-value-id="#{code.id}"]|) |> render_click()

      assert render(view) =~ "revoked"
    end
  end

  describe "as non-admin" do
    test "responds 403 forbidden", %{conn: conn} do
      conn = log_in_as_user(conn) |> get(~p"/admin/invites")
      assert conn.status == 403
    end
  end

  describe "unauthenticated" do
    test "redirects to /login", %{conn: conn} do
      conn = get(conn, ~p"/admin/invites")
      assert redirected_to(conn) == "/login"
    end
  end
end
