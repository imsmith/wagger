defmodule Wagger.InvitesTest do
  @moduledoc """
  Tests for the Wagger.Invites context.
  """

  use Wagger.DataCase

  alias Wagger.Accounts
  alias Wagger.Invites
  alias Wagger.Invites.InviteCode

  describe "create_code/2" do
    test "generates a unique URL-safe code" do
      assert {:ok, %InviteCode{code: c1}} = Invites.create_code()
      assert {:ok, %InviteCode{code: c2}} = Invites.create_code()
      assert c1 != c2
      assert byte_size(c1) >= 12
    end

    test "stores label, expires_at, max_uses when provided" do
      {:ok, code} =
        Invites.create_code(%{
          label: "team",
          expires_at: "2099-01-01T00:00:00Z",
          max_uses: 5
        })

      assert code.label == "team"
      assert code.max_uses == 5
      assert code.expires_at == "2099-01-01T00:00:00Z"
    end

    test "records created_by_user_id when given a user" do
      {:ok, _, _} = Accounts.create_user(%{"username" => "creator"})
      creator = Wagger.Repo.one(Wagger.Accounts.User)

      {:ok, code} = Invites.create_code(%{label: "x"}, creator)
      assert code.created_by_user_id == creator.id
    end
  end

  describe "list_codes/0" do
    test "returns codes newest-first with computed status" do
      {:ok, _} = Invites.create_code(%{label: "active"})
      {:ok, _expired} = Invites.create_code(%{label: "old", expires_at: "2000-01-01T00:00:00Z"})
      {:ok, revoked} = Invites.create_code(%{label: "rev"})
      {:ok, _} = Invites.revoke(revoked)

      list = Invites.list_codes()
      assert length(list) == 3

      labels_to_status = Enum.map(list, &{&1.label, &1.status})
      assert {"old", :expired} in labels_to_status
      assert {"rev", :revoked} in labels_to_status
      assert {"active", :active} in labels_to_status
      assert hd(list).label == "rev" or hd(list).label == "active"
    end
  end

  describe "redeem/2" do
    setup do
      {:ok, code} = Invites.create_code(%{label: "test"})
      %{code: code}
    end

    test "valid code creates user, links identity, increments uses", %{code: code} do
      payload = %{
        provider: "google",
        provider_uid: "g-1",
        email: "redeem@example.com",
        display_name: "R",
        raw_info: "{}"
      }

      assert {:ok, user} = Invites.redeem(code.code, payload)
      assert user.email == "redeem@example.com"
      assert user.invite_code_id == code.id
      assert Accounts.find_user_by_identity("google", "g-1").id == user.id

      reloaded = Wagger.Repo.get!(InviteCode, code.id)
      assert reloaded.uses_count == 1
    end

    test "expired code rejects with :expired" do
      {:ok, expired} =
        Invites.create_code(%{label: "exp", expires_at: "2000-01-01T00:00:00Z"})

      assert {:error, :expired} =
               Invites.redeem(expired.code, %{
                 provider: "google",
                 provider_uid: "x",
                 email: "x@x.com"
               })
    end

    test "exhausted code rejects with :exhausted", %{code: _code} do
      {:ok, capped} = Invites.create_code(%{label: "cap", max_uses: 1})

      {:ok, _} =
        Invites.redeem(capped.code, %{
          provider: "google",
          provider_uid: "1",
          email: "1@x.com"
        })

      assert {:error, :exhausted} =
               Invites.redeem(capped.code, %{
                 provider: "google",
                 provider_uid: "2",
                 email: "2@x.com"
               })
    end

    test "revoked code rejects with :revoked", %{code: code} do
      {:ok, _} = Invites.revoke(code)

      assert {:error, :revoked} =
               Invites.redeem(code.code, %{
                 provider: "google",
                 provider_uid: "r",
                 email: "r@x.com"
               })
    end

    test "unknown code rejects with :not_found" do
      assert {:error, :not_found} =
               Invites.redeem("nope", %{
                 provider: "google",
                 provider_uid: "?",
                 email: "?@x.com"
               })
    end
  end

  describe "revoke/1" do
    test "soft-revokes an invite code" do
      {:ok, code} = Invites.create_code(%{label: "x"})
      assert {:ok, revoked} = Invites.revoke(code)
      refute is_nil(revoked.revoked_at)
    end

    test "is idempotent on already-revoked codes" do
      {:ok, code} = Invites.create_code(%{label: "x"})
      {:ok, once} = Invites.revoke(code)
      {:ok, twice} = Invites.revoke(once)
      assert once.revoked_at == twice.revoked_at
    end
  end

  describe "users_for_code/1" do
    test "returns users who redeemed the given code" do
      {:ok, code} = Invites.create_code(%{label: "u"})

      {:ok, _} =
        Invites.redeem(code.code, %{
          provider: "google",
          provider_uid: "u-1",
          email: "u1@x.com"
        })

      users = Invites.users_for_code(code)
      assert length(users) == 1
      assert hd(users).email == "u1@x.com"
    end
  end
end
