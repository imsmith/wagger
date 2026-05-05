defmodule Wagger.Accounts.UserTest do
  @moduledoc """
  Tests for the Wagger.Accounts.User schema, focused on the auth-related
  fields and changeset rules added in this plan.
  """

  use Wagger.DataCase

  alias Wagger.Accounts.User

  describe "changeset/2" do
    test "casts email and role" do
      cs = User.changeset(%User{}, %{
        "username" => "alice",
        "email" => "alice@example.com",
        "role" => "user"
      })

      assert cs.valid?
      assert get_change(cs, :email) == "alice@example.com"
      assert get_field(cs, :role) == "user"
    end

    test "rejects unknown role" do
      cs = User.changeset(%User{}, %{"username" => "alice", "role" => "wizard"})

      refute cs.valid?
      assert %{role: [_msg]} = errors_on(cs)
    end

    test "defaults role to 'user' when not provided on insert" do
      {:ok, user} =
        %User{} |> User.changeset(%{"username" => "alice"}) |> Wagger.Repo.insert()

      assert user.role == "user"
    end

    test "enforces unique email when present" do
      {:ok, _} =
        %User{}
        |> User.changeset(%{"username" => "alice", "email" => "x@y.com"})
        |> Wagger.Repo.insert()

      {:error, cs} =
        %User{}
        |> User.changeset(%{"username" => "bob", "email" => "x@y.com"})
        |> Wagger.Repo.insert()

      assert %{email: ["has already been taken"]} = errors_on(cs)
    end

    test "allows multiple users with nil email" do
      {:ok, _} = %User{} |> User.changeset(%{"username" => "a"}) |> Wagger.Repo.insert()
      {:ok, _} = %User{} |> User.changeset(%{"username" => "b"}) |> Wagger.Repo.insert()
    end
  end
end
