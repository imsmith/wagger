defmodule WaggerWeb.AuthController do
  @moduledoc """
  Handles OAuth login flows (request, callback) and post-OAuth invite-code
  redemption.
  """

  use WaggerWeb, :controller

  alias Wagger.Accounts
  alias WaggerWeb.Auth.OauthPayload
  alias WaggerWeb.AuthHTML

  plug :put_view, html: AuthHTML
  plug Ueberauth when action in [:request]
  plug :run_ueberauth_callback when action in [:callback]

  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_failure: _}} = conn, _params) do
    conn
    |> put_flash(:error, "We couldn't sign in with that provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    payload = OauthPayload.from_auth(auth)
    handle_payload(conn, payload)
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "We couldn't sign in with that provider.")
    |> redirect(to: ~p"/login")
  end

  defp handle_payload(conn, %{email_verified?: false}) do
    conn
    |> put_flash(:error, "Your provider must give us a verified email address.")
    |> redirect(to: ~p"/login")
  end

  defp handle_payload(conn, payload) do
    case Accounts.find_user_by_identity(payload.provider, payload.provider_uid) do
      %{} = user ->
        log_in(conn, user)

      nil ->
        case Accounts.get_user_by_email(payload.email) do
          %{} = user ->
            {:ok, _} =
              Accounts.link_identity(user, payload.provider, %{
                provider_uid: payload.provider_uid,
                email: payload.email,
                raw_info: payload.raw_info
              })

            log_in(conn, user)

          nil ->
            register_new_email(conn, payload)
        end
    end
  end

  # Routes a new-email registration to either the bootstrap-admin path or
  # the invite-code prompt.
  #
  # HAZARD: leaving WAGGER_BOOTSTRAP_ADMIN_EMAIL set after first admin
  # sign-in means any OAuth identity matching that email becomes admin.
  # Unset the env var on the deploy after first use.
  defp register_new_email(conn, payload) do
    bootstrap = Application.get_env(:wagger, :bootstrap_admin_email)

    if is_binary(bootstrap) and bootstrap == payload.email do
      {:ok, user} =
        Accounts.register_oauth_user(%{
          email: payload.email,
          display_name: payload.display_name,
          role: "admin"
        })

      {:ok, _} =
        Accounts.link_identity(user, payload.provider, %{
          provider_uid: payload.provider_uid,
          email: payload.email,
          raw_info: payload.raw_info
        })

      log_in(conn, user)
    else
      conn
      |> put_session(:pending_oauth, %{
        "provider" => payload.provider,
        "provider_uid" => payload.provider_uid,
        "email" => payload.email,
        "display_name" => payload.display_name,
        "raw_info" => payload.raw_info
      })
      |> redirect(to: ~p"/auth/invite")
    end
  end

  def invite_form(conn, _params) do
    case get_session(conn, :pending_oauth) do
      nil -> redirect(conn, to: ~p"/login")
      _ -> render(conn, :invite, layout: false)
    end
  end

  def invite_submit(conn, %{"code" => code}) do
    case get_session(conn, :pending_oauth) do
      nil ->
        redirect(conn, to: ~p"/login")

      payload ->
        case Wagger.Invites.redeem(code, %{
               provider: payload["provider"],
               provider_uid: payload["provider_uid"],
               email: payload["email"],
               display_name: payload["display_name"],
               raw_info: payload["raw_info"]
             }) do
          {:ok, user} ->
            log_in(conn, user)

          {:error, reason} ->
            conn
            |> put_flash(:error, invite_error_message(reason))
            |> render(:invite, layout: false)
        end
    end
  end

  defp invite_error_message(:not_found), do: "That invite code is not recognized."
  defp invite_error_message(:revoked), do: "That invite code has been revoked."
  defp invite_error_message(:expired), do: "That invite code has expired."
  defp invite_error_message(:exhausted), do: "That invite code has no uses left."
  defp invite_error_message(_), do: "That invite code can't be used."

  defp log_in(conn, user) do
    return_to = get_session(conn, :return_to) || "/"

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> delete_session(:pending_oauth)
    |> delete_session(:return_to)
    |> redirect(to: return_to)
  end

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end

  # Runs Ueberauth's plug for the callback path so the strategy can parse the
  # OAuth response and populate `:ueberauth_auth` / `:ueberauth_failure`. Skipped
  # when those assigns are already present (tests inject them directly).
  defp run_ueberauth_callback(%{assigns: assigns} = conn, _opts)
       when is_map_key(assigns, :ueberauth_auth) or is_map_key(assigns, :ueberauth_failure) do
    conn
  end

  defp run_ueberauth_callback(conn, _opts) do
    Ueberauth.call(conn, Ueberauth.init([]))
  end
end
