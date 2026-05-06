defmodule WaggerWeb.InviteCodeLive do
  @moduledoc """
  Admin LiveView for invite-code management.
  """

  use WaggerWeb, :live_view

  alias Wagger.Invites

  def mount(_params, _session, socket) do
    {:ok, assign_codes(socket) |> assign(:new_code_revealed, nil)}
  end

  def handle_event("create", %{"invite" => params}, socket) do
    attrs = %{
      label: params["label"],
      max_uses: parse_int(params["max_uses"]),
      expires_at: empty_to_nil(params["expires_at"])
    }

    case Invites.create_code(attrs, socket.assigns.current_user) do
      {:ok, code} ->
        {:noreply, socket |> assign(:new_code_revealed, code.code) |> assign_codes()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Couldn't create code.")}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    code = Enum.find(socket.assigns.codes, &(&1.id == String.to_integer(id)))
    if code, do: Invites.revoke(code)
    {:noreply, assign_codes(socket)}
  end

  defp assign_codes(socket), do: assign(socket, :codes, Invites.list_codes())

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
