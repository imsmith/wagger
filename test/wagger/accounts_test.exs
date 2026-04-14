defmodule Wagger.AccountsTest do
  @moduledoc """
  Tests for the Wagger.Accounts context module.

  Covers user creation, API key authentication, and setup state detection.
  """

  use Wagger.DataCase

  alias Wagger.Accounts
  alias Wagger.Accounts.User

  describe "create_user/1" do
    test "returns {:ok, user, api_key} with valid attrs" do
      assert {:ok, %User{} = user, api_key} = Accounts.create_user(%{"username" => "alice"})
      assert user.username == "alice"
      assert is_binary(api_key)
      assert byte_size(api_key) > 0
    end

    test "rejects duplicate username" do
      assert {:ok, _, _} = Accounts.create_user(%{"username" => "alice"})
      assert {:error, changeset} = Accounts.create_user(%{"username" => "alice"})
      assert %{username: ["has already been taken"]} = errors_on(changeset)
    end

    test "requires username" do
      assert {:error, changeset} = Accounts.create_user(%{})
      assert %{username: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects username that is not a lowercase slug" do
      assert {:error, changeset} = Accounts.create_user(%{"username" => "Alice"})
      assert %{username: [_msg]} = errors_on(changeset)
    end
  end

  describe "authenticate_by_api_key/1" do
    test "returns {:ok, user} for a valid key" do
      assert {:ok, user, api_key} = Accounts.create_user(%{"username" => "bob"})
      assert {:ok, found} = Accounts.authenticate_by_api_key(api_key)
      assert found.id == user.id
      assert found.username == "bob"
    end

    test "returns :error for an invalid key" do
      assert :error = Accounts.authenticate_by_api_key("notavalidkey")
    end
  end

  describe "setup_required?/0" do
    test "returns true when no users exist" do
      assert Accounts.setup_required?() == true
    end

    test "returns false when at least one user exists" do
      {:ok, _, _} = Accounts.create_user(%{"username" => "carol"})
      assert Accounts.setup_required?() == false
    end
  end
end
