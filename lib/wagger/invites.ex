defmodule Wagger.Invites do
  @moduledoc """
  Context for invite codes — generation, redemption, listing, revocation.
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Accounts
  alias Wagger.Accounts.User
  alias Wagger.Invites.InviteCode

  @code_byte_length 12

  @doc """
  Creates a new invite code with a random URL-safe slug.
  """
  def create_code(attrs \\ %{}, created_by \\ nil) do
    full_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("code", generate_code())
      |> Map.put("created_by_user_id", created_by && created_by.id)

    %InviteCode{} |> InviteCode.changeset(full_attrs) |> Repo.insert()
  end

  @doc """
  Returns all codes, newest first, with a computed `:status` virtual field
  set to `:active`, `:expired`, `:revoked`, or `:exhausted`.
  """
  def list_codes do
    InviteCode
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Enum.map(&with_status/1)
  end

  @doc """
  Atomically redeems a code: creates a User, links an OauthIdentity, bumps
  the code's `uses_count`. Returns `{:ok, user}` or
  `{:error, :not_found | :revoked | :expired | :exhausted | changeset}`.

  `oauth_payload` is a map with `:provider`, `:provider_uid`, `:email`,
  optional `:display_name`, optional `:raw_info`.
  """
  def redeem(code_string, oauth_payload) when is_binary(code_string) and is_map(oauth_payload) do
    Repo.transaction(fn ->
      with {:ok, code} <- fetch_redeemable(code_string),
           {:ok, user} <-
             Accounts.register_oauth_user(%{
               email: oauth_payload[:email],
               display_name: oauth_payload[:display_name],
               role: "user",
               invite_code_id: code.id
             }),
           {:ok, _} <-
             Accounts.link_identity(user, oauth_payload[:provider], %{
               provider_uid: oauth_payload[:provider_uid],
               email: oauth_payload[:email],
               raw_info: oauth_payload[:raw_info]
             }),
           {:ok, _} <-
             code
             |> InviteCode.changeset(%{"uses_count" => code.uses_count + 1})
             |> Repo.update() do
        user
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Soft-revokes an invite code. Idempotent."
  def revoke(%InviteCode{revoked_at: nil} = code) do
    code
    |> InviteCode.changeset(%{"revoked_at" => DateTime.to_string(DateTime.utc_now())})
    |> Repo.update()
  end

  def revoke(%InviteCode{} = code), do: {:ok, code}

  @doc "Returns users who redeemed the given code."
  def users_for_code(%InviteCode{} = code) do
    Repo.all(from u in User, where: u.invite_code_id == ^code.id)
  end

  # ----- private helpers -----

  defp generate_code do
    :crypto.strong_rand_bytes(@code_byte_length) |> Base.url_encode64(padding: false)
  end

  defp fetch_redeemable(code_string) do
    case Repo.get_by(InviteCode, code: code_string) do
      nil -> {:error, :not_found}
      %InviteCode{revoked_at: rev} when not is_nil(rev) -> {:error, :revoked}
      %InviteCode{} = code -> validate_redeemable(code)
    end
  end

  defp validate_redeemable(%InviteCode{} = code) do
    cond do
      expired?(code) -> {:error, :expired}
      exhausted?(code) -> {:error, :exhausted}
      true -> {:ok, code}
    end
  end

  defp expired?(%InviteCode{expires_at: nil}), do: false

  defp expired?(%InviteCode{expires_at: when_str}) do
    case DateTime.from_iso8601(when_str) do
      {:ok, dt, _} -> DateTime.compare(dt, DateTime.utc_now()) == :lt
      _ -> false
    end
  end

  defp exhausted?(%InviteCode{max_uses: nil}), do: false
  defp exhausted?(%InviteCode{uses_count: u, max_uses: m}), do: u >= m

  defp with_status(%InviteCode{} = code) do
    status =
      cond do
        not is_nil(code.revoked_at) -> :revoked
        expired?(code) -> :expired
        exhausted?(code) -> :exhausted
        true -> :active
      end

    Map.put(code, :status, status)
  end
end
