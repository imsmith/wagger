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

    test "returns error for an invalid key" do
      assert {:error, %Comn.Errors.ErrorStruct{code: "wagger.accounts/auth_failed"}} =
               Accounts.authenticate_by_api_key("notavalidkey")
    end
  end

  describe "bootstrap_admin/0" do
    setup do
      Application.put_env(:wagger, :bootstrap_admin_email, "boot@x.com")
      Application.put_env(:wagger, :bootstrap_admin_password, "correct-horse-battery")

      on_exit(fn ->
        Application.delete_env(:wagger, :bootstrap_admin_email)
        Application.delete_env(:wagger, :bootstrap_admin_password)
      end)
    end

    test "seeds an admin with a working password into an empty database" do
      assert {:ok, %User{role: "admin", email: "boot@x.com"}} = Accounts.bootstrap_admin()
      assert {:ok, _} = Accounts.authenticate_by_password("boot@x.com", "correct-horse-battery")
      assert Accounts.bootstrap_admin() == :noop
    end

    test "is a no-op once any user exists" do
      {:ok, _, _} = Accounts.create_user(%{"username" => "existing"})
      assert Accounts.bootstrap_admin() == :noop
      refute Repo.get_by(User, email: "boot@x.com")
    end

    test "is a no-op without a configured password" do
      Application.delete_env(:wagger, :bootstrap_admin_password)
      assert Accounts.bootstrap_admin() == :noop
      assert Accounts.setup_required?()
    end

    test "rolls back the user when the password is too short" do
      Application.put_env(:wagger, :bootstrap_admin_password, "short")
      assert {:error, %Ecto.Changeset{}} = Accounts.bootstrap_admin()
      assert Accounts.setup_required?()
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

  describe "register_oauth_user/1" do
    test "creates a user with derived username from email local-part" do
      assert {:ok, user} =
               Accounts.register_oauth_user(%{
                 email: "alice@example.com",
                 display_name: "Alice",
                 role: "user"
               })

      assert user.email == "alice@example.com"
      assert user.username == "alice"
      assert user.role == "user"
      assert is_nil(user.password_hash)
      assert is_nil(user.api_key_hash)
    end

    test "appends a random suffix when username collides" do
      {:ok, _} =
        Accounts.register_oauth_user(%{email: "alice@a.com", display_name: "A"})

      {:ok, second} =
        Accounts.register_oauth_user(%{email: "alice@b.com", display_name: "A"})

      assert String.starts_with?(second.username, "alice-")
      refute second.username == "alice"
    end

    test "slugifies a non-slug local-part" do
      {:ok, user} =
        Accounts.register_oauth_user(%{email: "Alice.Smith+work@example.com"})

      assert user.username == "alice-smith-work"
    end
  end

  describe "get_user_by_email/1" do
    test "returns the user when one matches" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "x@y.com"})
      assert ^user = Accounts.get_user_by_email("x@y.com")
    end

    test "returns nil when no user matches" do
      assert is_nil(Accounts.get_user_by_email("nobody@nowhere.com"))
    end

    test "matches regardless of case" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "mixed@case.com"})

      assert %{id: id} = Accounts.get_user_by_email("Mixed@Case.com")
      assert id == user.id
    end

    test "ignores surrounding whitespace" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "spaced@out.com"})

      assert %{id: id} = Accounts.get_user_by_email("  spaced@out.com ")
      assert id == user.id
    end

    test "stores the address downcased and trimmed" do
      {:ok, user} = Accounts.register_oauth_user(%{email: " Loud@SHOUTING.com "})

      assert user.email == "loud@shouting.com"
    end
  end

  describe "set_password/2 and authenticate_by_password/2" do
    test "set_password hashes and stores; authenticate_by_password verifies" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "p@p.com"})

      {:ok, updated} = Accounts.set_password(user, "correct-horse-battery")
      refute is_nil(updated.password_hash)
      refute updated.password_hash == "correct-horse-battery"

      assert {:ok, found} = Accounts.authenticate_by_password("p@p.com", "correct-horse-battery")
      assert found.id == user.id

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_password("p@p.com", "wrong")
    end

    test "set_password rejects passwords shorter than 12 characters" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "s@s.com"})
      assert {:error, cs} = Accounts.set_password(user, "short")
      assert %{password_hash: [_msg]} = errors_on(cs)
    end

    test "authenticate_by_password accepts a differently-cased or padded address" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "case@login.com"})
      {:ok, _} = Accounts.set_password(user, "correct-horse-battery")

      assert {:ok, _} =
               Accounts.authenticate_by_password("Case@Login.com", "correct-horse-battery")

      assert {:ok, _} =
               Accounts.authenticate_by_password(" case@login.com ", "correct-horse-battery")
    end

    test "authenticate_by_password returns :invalid_credentials for unknown email" do
      assert {:error, :invalid_credentials} =
               Accounts.authenticate_by_password("ghost@nowhere.com", "anything")
    end
  end

  describe "clear_password/1" do
    test "nils the password_hash when another auth method exists" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "c@c.com"})
      {:ok, _} = Accounts.set_password(user, "long-enough-pass")

      # Add a fake oauth identity so the user still has an auth method.
      {:ok, _identity} =
        %Wagger.Accounts.OauthIdentity{}
        |> Wagger.Accounts.OauthIdentity.changeset(%{
          provider: "github",
          provider_uid: "12345",
          email: "c@c.com",
          user_id: user.id
        })
        |> Wagger.Repo.insert()

      assert {:ok, cleared} = Accounts.clear_password(user)
      assert is_nil(cleared.password_hash)
    end

    test "refuses when password is the only auth method" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "lone@p.com"})
      {:ok, user_with_pw} = Accounts.set_password(user, "long-enough-pass")

      assert {:error, %Comn.Errors.ErrorStruct{code: "wagger.accounts/orphan_account"}} =
               Accounts.clear_password(user_with_pw)
    end
  end

  describe "link_identity/3" do
    test "creates an OauthIdentity for the given user" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "i@i.com"})

      assert {:ok, identity} =
               Accounts.link_identity(user, "google", %{
                 provider_uid: "abc-123",
                 email: "i@i.com",
                 raw_info: "{}"
               })

      assert identity.user_id == user.id
      assert identity.provider == "google"
      assert identity.provider_uid == "abc-123"
    end

    test "rejects duplicate (provider, provider_uid)" do
      {:ok, user1} = Accounts.register_oauth_user(%{email: "1@1.com"})
      {:ok, user2} = Accounts.register_oauth_user(%{email: "2@2.com"})

      {:ok, _} = Accounts.link_identity(user1, "google", %{provider_uid: "x", email: "1@1.com"})

      assert {:error, cs} =
               Accounts.link_identity(user2, "google", %{provider_uid: "x", email: "2@2.com"})

      assert %{provider_uid: [_msg]} = errors_on(cs)
    end
  end

  describe "find_user_by_identity/2" do
    test "returns the user via the (provider, provider_uid) lookup" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "f@f.com"})

      {:ok, _} =
        Accounts.link_identity(user, "github", %{provider_uid: "g-1", email: "f@f.com"})

      assert ^user = Accounts.find_user_by_identity("github", "g-1")
    end

    test "returns nil for unknown identity" do
      assert is_nil(Accounts.find_user_by_identity("github", "nope"))
    end
  end

  describe "unlink_identity/2" do
    test "removes the identity when the user has another auth method" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "u@u.com"})
      {:ok, _} = Accounts.set_password(user, "long-enough-pass")

      {:ok, identity} =
        Accounts.link_identity(user, "google", %{provider_uid: "u-1", email: "u@u.com"})

      assert {:ok, _} = Accounts.unlink_identity(user, identity.id)
      assert is_nil(Accounts.find_user_by_identity("google", "u-1"))
    end

    test "refuses when the identity is the only auth method" do
      {:ok, user} = Accounts.register_oauth_user(%{email: "o@o.com"})

      {:ok, identity} =
        Accounts.link_identity(user, "google", %{provider_uid: "o-1", email: "o@o.com"})

      assert {:error, %Comn.Errors.ErrorStruct{code: "wagger.accounts/orphan_account"}} =
               Accounts.unlink_identity(user, identity.id)
    end
  end
end
