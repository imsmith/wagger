defmodule WaggerWeb.SessionController do
  @moduledoc """
  Renders the login page and handles password sign-in and sign-out.
  """

  use WaggerWeb, :controller

  alias Wagger.Accounts
  alias Wagger.OauthCredentials
  alias WaggerWeb.SessionHTML

  plug :put_view, html: SessionHTML

  def new(conn, _params) do
    render(conn, :new,
      layout: false,
      providers: providers_state()
    )
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_by_password(email, password) do
      {:ok, user} ->
        return_to = get_session(conn, :return_to) || "/"

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:user_id, user.id)
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Email or password incorrect.")
        |> render(:new, layout: false, providers: providers_state())
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/login")
  end

  defp providers_state do
    %{
      google: OauthCredentials.provider_configured?("google"),
      github: OauthCredentials.provider_configured?("github")
    }
  end
end
