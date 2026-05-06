defmodule WaggerWeb.AccountLive do
  @moduledoc "Self-service account settings: identities, password."

  use WaggerWeb, :live_view

  alias Wagger.Accounts
  alias Wagger.Accounts.OauthIdentity
  alias Wagger.Repo

  import Ecto.Query

  def mount(_params, _session, socket) do
    {:ok, assign_state(socket)}
  end

  def handle_event("set_password", %{"password" => %{"value" => v}}, socket) do
    case Accounts.set_password(socket.assigns.current_user, v) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Password set.") |> assign_state()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Password must be at least 12 characters.")}
    end
  end

  def handle_event("clear_password", _params, socket) do
    case Accounts.clear_password(socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Password removed.") |> assign_state()}

      {:error, %{message: msg}} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("unlink", %{"id" => id}, socket) do
    case Accounts.unlink_identity(socket.assigns.current_user, String.to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Identity unlinked.") |> assign_state()}

      {:error, %{message: msg}} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp assign_state(socket) do
    user = Repo.get!(Wagger.Accounts.User, socket.assigns.current_user.id)
    identities = Repo.all(from i in OauthIdentity, where: i.user_id == ^user.id)

    socket
    |> assign(:current_user, user)
    |> assign(:identities, identities)
    |> assign(:has_password, not is_nil(user.password_hash))
  end
end
