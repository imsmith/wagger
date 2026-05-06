defmodule WaggerWeb.Hooks.AuthHook do
  @moduledoc """
  on_mount hooks that load the current user (and optionally enforce
  admin role) for LiveViews.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Wagger.Repo
  alias Wagger.Accounts.User

  def on_mount(:require_user, _params, %{"user_id" => user_id}, socket) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      nil -> halt_to_login(socket)
      %User{} = user -> {:cont, assign(socket, :current_user, user)}
    end
  end

  def on_mount(:require_user, _params, _session, socket) do
    halt_to_login(socket)
  end

  def on_mount(:require_admin, params, session, socket) do
    case on_mount(:require_user, params, session, socket) do
      {:cont, socket} ->
        if socket.assigns.current_user.role == "admin" do
          {:cont, socket}
        else
          {:halt, socket |> put_flash(:error, "Admin access required.") |> redirect(to: "/")}
        end

      halt ->
        halt
    end
  end

  defp halt_to_login(socket) do
    {:halt, socket |> put_flash(:error, "You need to sign in.") |> redirect(to: "/login")}
  end
end
