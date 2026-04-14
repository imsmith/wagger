defmodule WaggerWeb.UserLive do
  @moduledoc """
  LiveView for user management.

  Lists all users, creates new users (displaying the API key once on success),
  and deletes users.
  """

  use WaggerWeb, :live_view

  alias Wagger.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, Accounts.list_users())
     |> assign(:new_api_key, nil)
     |> assign(:active_nav, :users)
     |> assign(:page_title, "Users")}
  end

  @impl true
  def handle_event("create_user", %{"username" => username, "display_name" => display_name}, socket) do
    case Accounts.create_user(%{"username" => username, "display_name" => display_name}) do
      {:ok, _user, api_key} ->
        {:noreply,
         socket
         |> assign(:users, Accounts.list_users())
         |> assign(:new_api_key, api_key)
         |> put_flash(:info, "User created.")}

      {:error, changeset} ->
        message =
          changeset.errors
          |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
          |> Enum.join(", ")

        {:noreply, put_flash(socket, :error, "Could not create user — #{message}")}
    end
  end

  @impl true
  def handle_event("dismiss_key", _params, socket) do
    {:noreply, assign(socket, :new_api_key, nil)}
  end

  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    if user.username == "admin" do
      {:noreply, put_flash(socket, :error, "Cannot delete the admin user")}
    else
      {:ok, _} = Accounts.delete_user(user)
      {:noreply, assign(socket, :users, Accounts.list_users())}
    end
  end
end
