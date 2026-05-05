defmodule WaggerWeb.Auth.OauthPayload do
  @moduledoc """
  Normalizes an `Ueberauth.Auth` struct into a flat payload map our
  Accounts/Invites contexts can consume. Also extracts a verified-email
  flag per provider's conventions.
  """

  @type t :: %{
          provider: String.t(),
          provider_uid: String.t(),
          email: String.t() | nil,
          email_verified?: boolean(),
          display_name: String.t() | nil,
          raw_info: String.t()
        }

  @doc "Builds a payload from an Ueberauth.Auth struct."
  def from_auth(auth) when is_map(auth) do
    %{
      provider: to_string(auth.provider),
      provider_uid: to_string(auth.uid),
      email: auth.info && auth.info.email,
      email_verified?: verified?(auth),
      display_name: display_name(auth),
      raw_info: encode_raw(auth)
    }
  end

  defp verified?(%{provider: :google, extra: %{raw_info: %{user: %{"email_verified" => v}}}}),
    do: v == true

  defp verified?(%{provider: :google, extra: %{raw_info: %{"email_verified" => v}}}),
    do: v == true

  defp verified?(%{provider: :github, info: %{email: email}, extra: %{raw_info: raw}})
       when is_binary(email) do
    emails = (raw["emails"] || raw[:emails] || []) |> List.wrap()

    Enum.any?(emails, fn e ->
      (e["email"] == email or e[:email] == email) and
        (e["primary"] == true or e[:primary] == true) and
        (e["verified"] == true or e[:verified] == true)
    end)
  end

  defp verified?(_), do: false

  defp display_name(%{info: info}) do
    info && (info.name || info.nickname)
  end

  defp display_name(_), do: nil

  defp encode_raw(auth) do
    safe = Map.drop(auth, [:credentials])
    Eden.encode!(:erlang.term_to_binary(safe) |> Base.encode64())
  rescue
    e in [ArgumentError, Protocol.UndefinedError] ->
      _ = e
      "{}"
  end
end
