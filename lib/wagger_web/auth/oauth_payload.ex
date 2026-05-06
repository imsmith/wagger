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
    email = auth.info && auth.info.email

    %{
      provider: to_string(auth.provider),
      provider_uid: to_string(auth.uid),
      email: email,
      email_verified?: is_binary(email) and verified?(auth),
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

  # Stores the auth payload (minus credentials/tokens) as base64-encoded
  # BERT for faithful forensic preservation. Decode with
  # `Base.decode64!/1 |> :erlang.binary_to_term/1`. Falls back to "" on
  # any error so callback handling never raises on a malformed payload.
  defp encode_raw(auth) do
    auth
    |> Map.drop([:credentials])
    |> :erlang.term_to_binary()
    |> Base.encode64()
  rescue
    _e in [ArgumentError, Protocol.UndefinedError] -> ""
  end
end
