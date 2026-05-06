defmodule WaggerWeb.OauthCredentialsLiveTest do
  @moduledoc false
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.OauthCredentials

  setup %{conn: conn} do
    conn = log_in_as_admin(conn)

    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)

    %{conn: conn}
  end

  test "shows masked secret when credentials exist", %{conn: conn} do
    {:ok, _} = OauthCredentials.upsert("google", "id-x", "secret-x")

    {:ok, _view, html} = live(conn, ~p"/admin/oauth")
    assert html =~ "id-x"
    assert html =~ "••••"
    refute html =~ "secret-x"
  end

  test "saves new credentials via form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/oauth")

    view
    |> form("#cred-form-google", cred: %{client_id: "fresh-id", client_secret: "fresh-secret"})
    |> render_submit(%{"provider" => "google"})

    assert {:ok, %{client_id: "fresh-id", client_secret: "fresh-secret"}} =
             OauthCredentials.get("google")
  end
end
