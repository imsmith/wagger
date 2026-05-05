defmodule Wagger.Invites do
  @moduledoc """
  Context for invite codes — generation, redemption, listing, revocation.
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Invites.InviteCode

  @code_byte_length 12

  @doc """
  Creates a new invite code with a random URL-safe slug.

  `attrs` may include optional `:label`, `:expires_at`, `:max_uses`.
  `created_by` is the User who created the code, or nil.
  """
  def create_code(attrs \\ %{}, created_by \\ nil) do
    full_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("code", generate_code())
      |> Map.put("created_by_user_id", created_by && created_by.id)

    %InviteCode{} |> InviteCode.changeset(full_attrs) |> Repo.insert()
  end

  defp generate_code do
    :crypto.strong_rand_bytes(@code_byte_length) |> Base.url_encode64(padding: false)
  end
end
