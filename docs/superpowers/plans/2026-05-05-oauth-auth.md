# OAuth + Local-Password Auth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Ueberauth-based OAuth (Google + GitHub) and local-password auth, gating wagger's browser/LiveView surface, with invite-code-gated registration, admin role + admin UI for invites and OAuth credentials, and `Comn.Secrets`-backed encryption of OAuth client secrets.

**Architecture:** OAuth callbacks resolve to existing identities → existing-email matches → bootstrap-admin → invite-prompt, in that order. Sessions are cookie-backed; route gating via plugs (`FetchCurrentUser`/`RequireUser`/`RequireAdmin`) and a LiveView `AuthHook`. OAuth client secrets live encrypted in a DB table; env vars seed the table on first boot only. Local-password is a login path (not a signup path); signup is OAuth + invite code or bootstrap-admin email.

**Tech Stack:** Elixir 1.15+, Phoenix 1.8.4, Phoenix LiveView 1.1, ecto_sqlite3, `ueberauth`, `ueberauth_google`, `ueberauth_github`, `argon2_elixir`, existing `comn` library (provides `Comn.Secrets.Local`).

**Spec:** `docs/superpowers/specs/2026-05-05-oauth-auth-design.md`

**Conventions in this codebase you must follow:**

- Migrations live in `priv/repo/migrations/`. Filename format `YYYYMMDDHHMMSS_<snake>.exs`. Generate via `mix ecto.gen.migration <name>` to get a fresh timestamp; do not invent timestamps by hand.
- Schemas use `@timestamps_opts [type: :string, autogenerate: {Mod, :timestamp_now, []}]`. The `Wagger.Accounts.Application` and `Wagger.Accounts.User` modules expose `timestamp_now/0` returning `DateTime.to_string(DateTime.utc_now())`. New schemas in this plan reuse the same convention by exposing their own `timestamp_now/0`.
- IDs are default integer (no UUIDs).
- Tests use `use Wagger.DataCase` for context tests and `use WaggerWeb.ConnCase` for controller/plug/LiveView tests. ConnCase already provides `import Plug.Conn`, `import Phoenix.ConnTest`, and `:verified_routes`.
- Errors from contexts wrap with `Comn.Errors.Registry.error!("wagger.<context>/<reason>", ...)` returning `Comn.Errors.ErrorStruct`. Mirror this for new error tuples.
- The `:eden` library provides EDN encoding (`Eden.encode!/1`, `Eden.decode!/1`). Used for raw OAuth payload storage.
- LiveView routes mount via `live_session :name, on_mount: [...]`. Hooks live in `lib/wagger_web/hooks/`.
- Run tests with `mix test`. Run a single file with `mix test path/to/file_test.exs`. Run a single test with `mix test path/to/file.exs:LINE`.
- After every task, commit with a short imperative message — `feat:`, `fix:`, `test:`, `refactor:`, `docs:`, `chore:`. The commit message must reference the task number, e.g. `feat(auth): users.email + role columns (Task 1)`.

**Order:** Tasks are numbered sequentially. Phases group related tasks but execute in order — later tasks depend on earlier ones.

---

## Phase 1 — Schema foundation

### Task 1: Migration — add `email`, `role`, `invite_code_id` to `users`

**Files:**

- Create: `priv/repo/migrations/<timestamp>_add_auth_fields_to_users.exs`

- [ ] **Step 1: Generate the migration file**

```bash
mix ecto.gen.migration add_auth_fields_to_users
```

This creates the file with a fresh timestamp. Open the file and replace its body.

- [ ] **Step 2: Write the migration**

```elixir
defmodule Wagger.Repo.Migrations.AddAuthFieldsToUsers do
  use Ecto.Migration

  @moduledoc false

  def change do
    alter table(:users) do
      add :email, :string
      add :role, :string, default: "user", null: false
      add :invite_code_id, references(:invite_codes, on_delete: :nilify_all)
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL")
    create index(:users, [:invite_code_id])

    execute(
      "UPDATE users SET role = 'admin' WHERE username = 'admin'",
      "UPDATE users SET role = 'user' WHERE username = 'admin'"
    )
  end
end
```

The `references(:invite_codes, ...)` call requires that table to exist when the migration runs. Task 2 creates it; tests for Task 1 should run *after* Task 2's migration is in place. To keep the order clean, this migration's `change` is splittable — we'll fix the ordering via filename timestamps so Task 2's file sorts *earlier*. See Task 2 step 1.

- [ ] **Step 3: Do not run the migration yet**

We must create `invite_codes` (Task 2) and `oauth_identities` (Task 3) and `oauth_provider_credentials` (Task 4) before running the user-table alter. Mark this task complete after the file is in place; running migrations happens at the end of Phase 1 (Task 5).

- [ ] **Step 4: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(auth): add email, role, invite_code_id columns to users (Task 1)"
```

### Task 2: Migration — `invite_codes` table

**Files:**

- Create: `priv/repo/migrations/<timestamp>_create_invite_codes.exs`

- [ ] **Step 1: Generate with an earlier timestamp than Task 1's migration**

```bash
mix ecto.gen.migration create_invite_codes
```

The newly-generated migration will get a *later* timestamp than Task 1's by default (it runs later in real time). That's fine for *runtime* — migrations sort by timestamp, and the user-table alter requires this table to exist first. Rename the file produced in Task 1 to a timestamp **later than** the one produced in Task 2.

```bash
# After both files exist, find them:
ls priv/repo/migrations/ | tail -5
# Identify Task 1's file and Task 2's file. Rename Task 1's to a timestamp 1 second later than Task 2's.
mv priv/repo/migrations/<task1-timestamp>_add_auth_fields_to_users.exs \
   priv/repo/migrations/<task2-timestamp+1>_add_auth_fields_to_users.exs
```

(In practice you'll generate Tasks 2/3/4 first and then Task 1 last to avoid renaming. The ordering requirement is: `invite_codes`, `oauth_identities`, `oauth_provider_credentials` all *before* `add_auth_fields_to_users`.)

- [ ] **Step 2: Write the migration**

```elixir
defmodule Wagger.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:invite_codes) do
      add :code, :string, null: false
      add :label, :string
      add :expires_at, :string
      add :max_uses, :integer
      add :uses_count, :integer, default: 0, null: false
      add :revoked_at, :string
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :string)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:created_by_user_id])
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(auth): invite_codes table (Task 2)"
```

### Task 3: Migration — `oauth_identities` table

**Files:**

- Create: `priv/repo/migrations/<timestamp>_create_oauth_identities.exs`

- [ ] **Step 1: Generate**

```bash
mix ecto.gen.migration create_oauth_identities
```

- [ ] **Step 2: Write the migration**

```elixir
defmodule Wagger.Repo.Migrations.CreateOauthIdentities do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:oauth_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_uid, :string, null: false
      add :email, :string, null: false
      add :raw_info, :text
      timestamps(type: :string)
    end

    create unique_index(:oauth_identities, [:provider, :provider_uid])
    create index(:oauth_identities, [:user_id])
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(auth): oauth_identities table (Task 3)"
```

### Task 4: Migration — `oauth_provider_credentials` table

**Files:**

- Create: `priv/repo/migrations/<timestamp>_create_oauth_provider_credentials.exs`

- [ ] **Step 1: Generate**

```bash
mix ecto.gen.migration create_oauth_provider_credentials
```

- [ ] **Step 2: Write the migration**

```elixir
defmodule Wagger.Repo.Migrations.CreateOauthProviderCredentials do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:oauth_provider_credentials) do
      add :provider, :string, null: false
      add :client_id, :string, null: false
      add :client_secret_locked, :text, null: false
      timestamps(type: :string)
    end

    create unique_index(:oauth_provider_credentials, [:provider])
  end
end
```

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(auth): oauth_provider_credentials table (Task 4)"
```

### Task 5: Run all four migrations

- [ ] **Step 1: Verify ordering**

```bash
ls priv/repo/migrations/ | tail -5
```

Expected: `create_invite_codes`, `create_oauth_identities`, `create_oauth_provider_credentials`, `add_auth_fields_to_users` (last). If `add_auth_fields_to_users` is not last, rename its timestamp prefix.

- [ ] **Step 2: Run migrations**

```bash
mix ecto.migrate
```

Expected: four "[info] == Running ..." lines, each ending with `:ok`.

- [ ] **Step 3: Run existing tests to confirm nothing broke**

```bash
mix test
```

Expected: all existing tests pass. (No code changes yet beyond migrations and the data fix-up; existing schema modules still match the DB.)

- [ ] **Step 4: Commit**

No file changes here — but if `mix.lock` was touched (it shouldn't be), commit it. Otherwise skip.

---

## Phase 2 — Schemas & accounts context expansion

### Task 6: Update `User` schema for `email`, `role`, `invite_code_id`

**Files:**

- Modify: `lib/wagger/accounts/user.ex`
- Test: `test/wagger/accounts/user_test.exs` (new file)

- [ ] **Step 1: Write a failing schema test for the new fields**

Create `test/wagger/accounts/user_test.exs`:

```elixir
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
      assert get_change(cs, :role) == "user"
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
```

- [ ] **Step 2: Run to verify it fails**

```bash
mix test test/wagger/accounts/user_test.exs
```

Expected: failures because the schema doesn't yet declare `email`, `role`, `invite_code_id`, and the changeset doesn't validate role.

- [ ] **Step 3: Update the schema**

Replace the contents of `lib/wagger/accounts/user.ex`:

```elixir
defmodule Wagger.Accounts.User do
  @moduledoc """
  Ecto schema for a User — a human operator.

  Authentication paths: API key (existing), OAuth via linked
  `oauth_identities` (browser), and local password (browser).
  Usernames must be lowercase slugs and are unique. Email is
  optional but unique when present.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  @valid_roles ~w(admin user)

  schema "users" do
    field :username, :string
    field :display_name, :string
    field :email, :string
    field :role, :string, default: "user"
    field :password_hash, :string
    field :api_key_hash, :string

    belongs_to :invite_code, Wagger.Invites.InviteCode

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc """
  Changeset for creating or updating a User.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :display_name,
      :email,
      :role,
      :password_hash,
      :api_key_hash,
      :invite_code_id
    ])
    |> validate_required([:username])
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9\-]*$/,
      message: "must be a lowercase slug (letters, digits, hyphens)"
    )
    |> validate_inclusion(:role, @valid_roles)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> unique_constraint(:api_key_hash)
  end
end
```

(Note: `Wagger.Invites.InviteCode` doesn't exist yet — Task 7 creates it. Compilation will fail until Task 7. This is intentional; we'll write Task 7 right after and run the User test only once the InviteCode schema is in place.)

- [ ] **Step 4: Run user test (will still fail — InviteCode missing)**

Skip running here. Proceed to Task 7, then come back.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/accounts/user.ex test/wagger/accounts/user_test.exs
git commit -m "feat(auth): User schema gets email/role/invite_code (Task 6)"
```

### Task 7: New `InviteCode` schema and `Wagger.Invites` context skeleton

**Files:**

- Create: `lib/wagger/invites/invite_code.ex`
- Create: `lib/wagger/invites.ex`

- [ ] **Step 1: Create the schema**

```elixir
defmodule Wagger.Invites.InviteCode do
  @moduledoc """
  Ecto schema for an invite code. Codes are short, URL-safe slugs that
  gate registration of new users via OAuth. They may be labeled, expire,
  or be capped at a maximum number of uses, and can be soft-revoked.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  schema "invite_codes" do
    field :code, :string
    field :label, :string
    field :expires_at, :string
    field :max_uses, :integer
    field :uses_count, :integer, default: 0
    field :revoked_at, :string

    belongs_to :created_by, Wagger.Accounts.User, foreign_key: :created_by_user_id

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc "Changeset for creating an invite code."
  def changeset(code, attrs) do
    code
    |> cast(attrs, [:code, :label, :expires_at, :max_uses, :uses_count, :revoked_at, :created_by_user_id])
    |> validate_required([:code])
    |> unique_constraint(:code)
  end
end
```

- [ ] **Step 2: Create the context skeleton**

```elixir
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
```

- [ ] **Step 3: Compile and run all tests**

```bash
mix compile
mix test
```

Expected: compile succeeds, all existing tests pass, the User test from Task 6 passes (`role` validation, email uniqueness, etc.).

- [ ] **Step 4: Commit**

```bash
git add lib/wagger/invites/ lib/wagger/invites.ex
git commit -m "feat(auth): InviteCode schema + Invites context skeleton (Task 7)"
```

### Task 8: New `OauthIdentity` schema

**Files:**

- Create: `lib/wagger/accounts/oauth_identity.ex`

- [ ] **Step 1: Create the schema**

```elixir
defmodule Wagger.Accounts.OauthIdentity do
  @moduledoc """
  Ecto schema for an OAuth identity linked to a User. A User may have
  multiple identities across providers; identities are keyed uniquely
  by (provider, provider_uid).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  @valid_providers ~w(google github)

  schema "oauth_identities" do
    field :provider, :string
    field :provider_uid, :string
    field :email, :string
    field :raw_info, :string

    belongs_to :user, Wagger.Accounts.User

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  @doc "Changeset for creating or updating an OAuth identity."
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:provider, :provider_uid, :email, :raw_info, :user_id])
    |> validate_required([:provider, :provider_uid, :email, :user_id])
    |> validate_inclusion(:provider, @valid_providers)
    |> unique_constraint([:provider, :provider_uid],
      name: :oauth_identities_provider_provider_uid_index
    )
  end
end
```

- [ ] **Step 2: Compile**

```bash
mix compile
```

Expected: compiles cleanly.

- [ ] **Step 3: Commit**

```bash
git add lib/wagger/accounts/oauth_identity.ex
git commit -m "feat(auth): OauthIdentity schema (Task 8)"
```

### Task 9: Add `argon2_elixir` dependency

**Files:**

- Modify: `mix.exs`

- [ ] **Step 1: Add the dep**

In `mix.exs`, find the `defp deps do [...]` list and add at the end (before the closing `]`):

```elixir
      {:argon2_elixir, "~> 4.0"},
```

- [ ] **Step 2: Fetch**

```bash
mix deps.get
```

- [ ] **Step 3: Compile**

```bash
mix compile
```

Expected: compiles. `argon2_elixir` will compile a NIF on first build.

- [ ] **Step 4: Run tests to confirm baseline**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "chore(auth): add argon2_elixir dep (Task 9)"
```

### Task 10: `Wagger.Accounts` — username derivation, email-based lookup, password set/auth/clear

**Files:**

- Modify: `lib/wagger/accounts.ex`
- Modify: `test/wagger/accounts_test.exs`

- [ ] **Step 1: Write failing tests for the new functions**

Append to `test/wagger/accounts_test.exs` (inside the existing `defmodule`, before the final `end`):

```elixir
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: failures naming `register_oauth_user`, `get_user_by_email`, `set_password`, `authenticate_by_password`, `clear_password` as undefined.

- [ ] **Step 3: Implement**

Replace the contents of `lib/wagger/accounts.ex`:

```elixir
defmodule Wagger.Accounts do
  @moduledoc """
  Context module for users and authentication.

  Authentication paths:
  - API key (existing)
  - OAuth via linked `oauth_identities` (browser)
  - Local password (browser)
  """

  import Ecto.Query, warn: false

  alias Wagger.Repo
  alias Wagger.Accounts.{OauthIdentity, User}

  @username_suffix_bytes 3

  # ----- existing API-key-based functions -----

  @doc """
  Creates a user with a generated API key. Returns
  `{:ok, user, api_key_plaintext}` or `{:error, changeset}`.
  """
  def create_user(attrs \\ %{}) do
    api_key = generate_api_key()
    api_key_hash = hash_api_key(api_key)

    key = if Map.keys(attrs) |> List.first() |> is_atom(), do: :api_key_hash, else: "api_key_hash"
    attrs_with_hash = Map.put(attrs, key, api_key_hash)

    case %User{} |> User.changeset(attrs_with_hash) |> Repo.insert() do
      {:ok, user} -> {:ok, user, api_key}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Authenticates a user by raw API key. Returns `{:ok, user}` or `{:error, _}`."
  def authenticate_by_api_key(api_key) do
    hash = hash_api_key(api_key)

    case Repo.get_by(User, api_key_hash: hash) do
      nil -> {:error, Comn.Errors.Registry.error!("wagger.accounts/auth_failed")}
      user -> {:ok, user}
    end
  end

  def list_users, do: Repo.all(User)
  def get_user!(id), do: Repo.get!(User, id)

  def delete_user(%User{username: "admin"}) do
    {:error, Comn.Errors.Registry.error!("wagger.accounts/protected_user")}
  end

  def delete_user(%User{} = user), do: Repo.delete(user)

  def setup_required?, do: Repo.aggregate(User, :count, :id) == 0

  # ----- new functions for OAuth + password auth -----

  @doc """
  Registers a User created via OAuth (or otherwise without an API key).
  Derives a username from the email local-part. Does NOT generate an
  API key. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  def register_oauth_user(attrs) when is_map(attrs) do
    email = Map.get(attrs, :email) || Map.get(attrs, "email")
    base_username = derive_username(email)

    final_attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("username", available_username(base_username))
      |> Map.put_new("role", "user")

    %User{} |> User.changeset(final_attrs) |> Repo.insert()
  end

  defp derive_username(nil), do: random_username()

  defp derive_username(email) when is_binary(email) do
    [local, _domain] = String.split(email, "@", parts: 2)

    local
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> random_username()
      slug -> slug
    end
  end

  defp available_username(base) do
    case Repo.get_by(User, username: base) do
      nil -> base
      _ -> base <> "-" <> random_suffix()
    end
  end

  defp random_username, do: "user-" <> random_suffix()

  defp random_suffix do
    :crypto.strong_rand_bytes(@username_suffix_bytes)
    |> Base.url_encode64(padding: false)
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "")
  end

  @doc "Returns the user with the given email, or nil."
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Sets a password for the user. Argon2-hashes the plaintext.
  Returns `{:ok, updated_user}` or `{:error, changeset}`.
  Rejects passwords shorter than 12 characters.
  """
  def set_password(%User{} = user, plaintext) when is_binary(plaintext) do
    if String.length(plaintext) < 12 do
      cs =
        user
        |> User.changeset(%{})
        |> Ecto.Changeset.add_error(:password_hash, "must be at least 12 characters")

      {:error, cs}
    else
      hash = Argon2.hash_pwd_salt(plaintext)

      user
      |> User.changeset(%{"password_hash" => hash})
      |> Repo.update()
    end
  end

  @doc """
  Authenticates by email + plaintext password.
  Returns `{:ok, user}` or `{:error, :invalid_credentials}`.
  Constant-time on missing-user.
  """
  def authenticate_by_password(email, plaintext) when is_binary(email) and is_binary(plaintext) do
    case get_user_by_email(email) do
      nil ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{password_hash: nil} ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      %User{password_hash: hash} = user ->
        if Argon2.verify_pass(plaintext, hash) do
          {:ok, user}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  @doc """
  Clears the user's password. Refuses if doing so would leave the user
  with no remaining auth method (no linked OAuth identities and no API
  key). Returns `{:ok, user}` or `{:error, ErrorStruct}`.
  """
  def clear_password(%User{} = user) do
    if has_other_auth_method?(user, exclude: :password) do
      user
      |> User.changeset(%{"password_hash" => nil})
      |> Repo.update()
    else
      {:error, Comn.Errors.Registry.error!("wagger.accounts/orphan_account",
        message: "removing this would leave the account with no way to log in"
      )}
    end
  end

  @doc """
  Returns true if the user has at least one auth method other than the
  one named in `exclude`. `exclude` is one of `:password`, `:api_key`,
  or `{:oauth_identity, identity_id}`.
  """
  def has_other_auth_method?(%User{} = user, opts) do
    exclude = Keyword.get(opts, :exclude)

    has_password? = exclude != :password and not is_nil(user.password_hash)
    has_api_key? = exclude != :api_key and not is_nil(user.api_key_hash)

    identity_count =
      case exclude do
        {:oauth_identity, id} ->
          Repo.aggregate(
            from(i in OauthIdentity, where: i.user_id == ^user.id and i.id != ^id),
            :count,
            :id
          )

        _ ->
          Repo.aggregate(from(i in OauthIdentity, where: i.user_id == ^user.id), :count, :id)
      end

    has_password? or has_api_key? or identity_count > 0
  end

  defp generate_api_key do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp hash_api_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: all pass, including the existing API-key tests and the new OAuth/password tests.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/accounts.ex test/wagger/accounts_test.exs
git commit -m "feat(auth): Accounts — register_oauth_user, password set/auth/clear, no-orphan rule (Task 10)"
```

### Task 11: `Wagger.Accounts.link_identity/3` and `unlink_identity/2`

**Files:**

- Modify: `lib/wagger/accounts.ex`
- Modify: `test/wagger/accounts_test.exs`

- [ ] **Step 1: Append failing tests**

Add to `test/wagger/accounts_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: failures for the new functions.

- [ ] **Step 3: Implement**

Append to `lib/wagger/accounts.ex` (inside the module, before the final `end`):

```elixir
  @doc """
  Links a new OAuth identity to a user. `attrs` must contain
  `provider_uid`, `email`, and may contain `raw_info`.
  """
  def link_identity(%User{} = user, provider, attrs) when is_binary(provider) and is_map(attrs) do
    full =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("provider", provider)
      |> Map.put("user_id", user.id)

    %OauthIdentity{} |> OauthIdentity.changeset(full) |> Repo.insert()
  end

  @doc """
  Returns the User linked to the given (provider, provider_uid), or nil.
  """
  def find_user_by_identity(provider, provider_uid)
      when is_binary(provider) and is_binary(provider_uid) do
    case Repo.get_by(OauthIdentity, provider: provider, provider_uid: provider_uid) do
      nil -> nil
      identity -> Repo.get(User, identity.user_id)
    end
  end

  @doc """
  Removes an identity. Refuses if doing so would leave the user with no
  auth method.
  """
  def unlink_identity(%User{} = user, identity_id) when is_integer(identity_id) do
    if has_other_auth_method?(user, exclude: {:oauth_identity, identity_id}) do
      case Repo.get_by(OauthIdentity, id: identity_id, user_id: user.id) do
        nil ->
          {:error, Comn.Errors.Registry.error!("wagger.accounts/identity_not_found")}

        identity ->
          Repo.delete(identity)
      end
    else
      {:error, Comn.Errors.Registry.error!("wagger.accounts/orphan_account",
        message: "removing this would leave the account with no way to log in"
      )}
    end
  end
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/accounts_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/accounts.ex test/wagger/accounts_test.exs
git commit -m "feat(auth): Accounts.link_identity/find_user_by_identity/unlink_identity (Task 11)"
```

---

## Phase 3 — Invites context

### Task 12: `Wagger.Invites` — full surface (`list_codes`, `redeem`, `revoke`, `users_for_code`)

**Files:**

- Modify: `lib/wagger/invites.ex`
- Create: `test/wagger/invites_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/wagger/invites_test.exs`:

```elixir
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
      {:ok, expired} = Invites.create_code(%{label: "old", expires_at: "2000-01-01T00:00:00Z"})
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
```

- [ ] **Step 2: Run to confirm failures**

```bash
mix test test/wagger/invites_test.exs
```

Expected: failures naming `list_codes`, `redeem`, `revoke`, `users_for_code` and the `:status` virtual field.

- [ ] **Step 3: Implement**

Replace `lib/wagger/invites.ex`:

```elixir
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
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/invites_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/invites.ex test/wagger/invites_test.exs
git commit -m "feat(auth): Invites — list/redeem/revoke/users_for_code (Task 12)"
```

---

## Phase 4 — OAuth credentials with Comn.Secrets

### Task 13: `Wagger.OauthCredentials` — schema, context, env-var fallback

**Files:**

- Create: `lib/wagger/oauth_credentials/credential.ex`
- Create: `lib/wagger/oauth_credentials.ex`
- Create: `test/wagger/oauth_credentials_test.exs`

- [ ] **Step 1: Schema module**

Create `lib/wagger/oauth_credentials/credential.ex`:

```elixir
defmodule Wagger.OauthCredentials.Credential do
  @moduledoc """
  Ecto schema for an OAuth provider's credentials (client_id + locked
  client_secret). Secret is encrypted at rest via Wagger.Secrets.lock/1.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {__MODULE__, :timestamp_now, []}
  ]

  schema "oauth_provider_credentials" do
    field :provider, :string
    field :client_id, :string
    field :client_secret_locked, :string

    timestamps(type: :string)
  end

  @doc false
  def timestamp_now, do: DateTime.to_string(DateTime.utc_now())

  def changeset(cred, attrs) do
    cred
    |> cast(attrs, [:provider, :client_id, :client_secret_locked])
    |> validate_required([:provider, :client_id, :client_secret_locked])
    |> validate_inclusion(:provider, ~w(google github))
    |> unique_constraint(:provider)
  end
end
```

- [ ] **Step 2: Failing tests for the context**

Create `test/wagger/oauth_credentials_test.exs`:

```elixir
defmodule Wagger.OauthCredentialsTest do
  @moduledoc """
  Tests for the Wagger.OauthCredentials context.
  """

  use Wagger.DataCase

  alias Wagger.OauthCredentials

  setup do
    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)
  end

  describe "upsert/3 and get/1" do
    test "stores client_id cleartext, secret locked, retrievable plaintext" do
      assert {:ok, _} = OauthCredentials.upsert("google", "id-1", "secret-1")
      assert {:ok, %{client_id: "id-1", client_secret: "secret-1"}} = OauthCredentials.get("google")
    end

    test "upsert overwrites existing credentials for a provider" do
      {:ok, _} = OauthCredentials.upsert("google", "id-old", "secret-old")
      {:ok, _} = OauthCredentials.upsert("google", "id-new", "secret-new")
      assert {:ok, %{client_id: "id-new", client_secret: "secret-new"}} =
               OauthCredentials.get("google")
    end

    test "get returns :error when nothing stored" do
      assert :error = OauthCredentials.get("github")
    end
  end

  describe "load_into_app_env/0" do
    test "writes Application env for google when row exists" do
      {:ok, _} = OauthCredentials.upsert("google", "id-loaded", "secret-loaded")
      :ok = OauthCredentials.load_into_app_env()

      cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      assert cfg[:client_id] == "id-loaded"
      assert cfg[:client_secret] == "secret-loaded"
    end

    test "seeds DB from env vars when no row exists" do
      System.put_env("GITHUB_OAUTH_CLIENT_ID", "envid")
      System.put_env("GITHUB_OAUTH_CLIENT_SECRET", "envsecret")

      try do
        :ok = OauthCredentials.load_into_app_env()
        assert {:ok, %{client_id: "envid", client_secret: "envsecret"}} =
                 OauthCredentials.get("github")

        cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
        assert cfg[:client_id] == "envid"
      after
        System.delete_env("GITHUB_OAUTH_CLIENT_ID")
        System.delete_env("GITHUB_OAUTH_CLIENT_SECRET")
      end
    end

    test "is a no-op for a provider with no row and no env vars" do
      :ok = OauthCredentials.load_into_app_env()
      assert is_nil(Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth))
    end
  end

  describe "provider_configured?/1" do
    test "true when credentials present, false otherwise" do
      refute OauthCredentials.provider_configured?("google")
      {:ok, _} = OauthCredentials.upsert("google", "id", "sec")
      assert OauthCredentials.provider_configured?("google")
    end
  end
end
```

- [ ] **Step 3: Run to confirm failure**

```bash
mix test test/wagger/oauth_credentials_test.exs
```

Expected: module-not-loaded errors.

- [ ] **Step 4: Implement context**

Create `lib/wagger/oauth_credentials.ex`:

```elixir
defmodule Wagger.OauthCredentials do
  @moduledoc """
  Context for OAuth provider credentials.

  Credentials live in the `oauth_provider_credentials` table; the
  `client_secret` is encrypted at rest via `Wagger.Secrets.lock/1`.
  On boot (and after each upsert), `load_into_app_env/0` decrypts and
  publishes credentials to the `:ueberauth` Application environment so
  Ueberauth strategies can read them at request time.
  """

  alias Wagger.Repo
  alias Wagger.OauthCredentials.Credential

  @providers ~w(google github)

  @env_var %{
    "google" => {"GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_SECRET"},
    "github" => {"GITHUB_OAUTH_CLIENT_ID", "GITHUB_OAUTH_CLIENT_SECRET"}
  }

  @oauth_strategy %{
    "google" => Ueberauth.Strategy.Google.OAuth,
    "github" => Ueberauth.Strategy.Github.OAuth
  }

  @doc """
  Upserts credentials for a provider. Locks the secret with
  `Wagger.Secrets.lock/1`, persists, and refreshes the Application env.
  """
  def upsert(provider, client_id, client_secret)
      when provider in @providers and is_binary(client_id) and is_binary(client_secret) do
    with {:ok, locked} <- Wagger.Secrets.lock(client_secret),
         {:ok, cred} <- do_upsert(provider, client_id, locked),
         :ok <- load_into_app_env() do
      {:ok, cred}
    end
  end

  defp do_upsert(provider, client_id, locked_secret) do
    case Repo.get_by(Credential, provider: provider) do
      nil ->
        %Credential{}
        |> Credential.changeset(%{
          "provider" => provider,
          "client_id" => client_id,
          "client_secret_locked" => locked_secret
        })
        |> Repo.insert()

      existing ->
        existing
        |> Credential.changeset(%{
          "client_id" => client_id,
          "client_secret_locked" => locked_secret
        })
        |> Repo.update()
    end
  end

  @doc """
  Returns `{:ok, %{client_id: ..., client_secret: plaintext}}` for a
  configured provider, or `:error`.
  """
  def get(provider) when provider in @providers do
    case Repo.get_by(Credential, provider: provider) do
      nil ->
        :error

      %Credential{client_id: id, client_secret_locked: locked} ->
        case Wagger.Secrets.unlock(locked) do
          {:ok, plaintext} -> {:ok, %{client_id: id, client_secret: plaintext}}
          _ -> :error
        end
    end
  end

  @doc """
  Pushes all configured providers' credentials into the
  `:ueberauth` Application environment. For providers without DB
  credentials, attempts to seed from env vars (one-time bootstrap).
  Returns `:ok` always.
  """
  def load_into_app_env do
    Enum.each(@providers, &load_provider/1)
    :ok
  end

  defp load_provider(provider) do
    case get(provider) do
      {:ok, %{client_id: id, client_secret: secret}} ->
        publish(provider, id, secret)

      :error ->
        case env_var_creds(provider) do
          {:ok, id, secret} ->
            case do_upsert(provider, id, lock_or_keep(secret)) do
              {:ok, _} -> publish(provider, id, secret)
              _ -> :ok
            end

          :error ->
            :ok
        end
    end
  end

  defp env_var_creds(provider) do
    {id_var, secret_var} = Map.fetch!(@env_var, provider)
    id = System.get_env(id_var)
    secret = System.get_env(secret_var)

    if is_binary(id) and is_binary(secret) and id != "" and secret != "" do
      {:ok, id, secret}
    else
      :error
    end
  end

  defp lock_or_keep(plain) do
    case Wagger.Secrets.lock(plain) do
      {:ok, locked} -> locked
      _ -> plain
    end
  end

  defp publish(provider, client_id, client_secret) do
    strategy = Map.fetch!(@oauth_strategy, provider)
    Application.put_env(:ueberauth, strategy, client_id: client_id, client_secret: client_secret)
    :ok
  end

  @doc "Returns true when the provider has stored credentials."
  def provider_configured?(provider) when provider in @providers do
    case get(provider) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
```

- [ ] **Step 5: Run tests**

```bash
mix test test/wagger/oauth_credentials_test.exs
```

Expected: all pass. The Ueberauth.Strategy.Google.OAuth and Ueberauth.Strategy.Github.OAuth atoms are referenced as bare module names; they don't need the module to actually exist for `Application.put_env` to work — it just stores the key.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/oauth_credentials/ lib/wagger/oauth_credentials.ex test/wagger/oauth_credentials_test.exs
git commit -m "feat(auth): OauthCredentials context — upsert/get/load with Wagger.Secrets (Task 13)"
```

---

## Phase 5 — Ueberauth dependencies + AuthController

### Task 14: Add Ueberauth deps and base config

**Files:**

- Modify: `mix.exs`
- Modify: `config/config.exs`

- [ ] **Step 1: Add deps to mix.exs**

In `mix.exs` `deps/0` list, append:

```elixir
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"},
      {:ueberauth_github, "~> 0.8"},
```

- [ ] **Step 2: Fetch + compile**

```bash
mix deps.get
mix compile
```

Expected: deps fetch and compile.

- [ ] **Step 3: Add Ueberauth provider list to config**

Append to `config/config.exs` (after existing config blocks):

```elixir
config :ueberauth, Ueberauth,
  providers: [
    google: {Ueberauth.Strategy.Google, [default_scope: "email profile"]},
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]
```

- [ ] **Step 4: Run all tests**

```bash
mix test
```

Expected: all pass. Ueberauth's strategies don't run unless their controllers are wired; this config is inert until then.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock config/config.exs
git commit -m "chore(auth): add ueberauth + google + github deps (Task 14)"
```

### Task 15: `WaggerWeb.AuthController` — request action + skeleton

**Files:**

- Create: `lib/wagger_web/controllers/auth_controller.ex`
- Modify: `lib/wagger_web/router.ex`
- Create: `test/wagger_web/controllers/auth_controller_test.exs`

- [ ] **Step 1: Add routes (just the OAuth pair for now)**

In `lib/wagger_web/router.ex`, inside the existing first `scope "/", WaggerWeb do` block (the one with `:browser` only), add at the bottom of the block (after the `get "/mcp/download/:token", ...` line):

```elixir
    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
```

- [ ] **Step 2: Stub controller**

Create `lib/wagger_web/controllers/auth_controller.ex`:

```elixir
defmodule WaggerWeb.AuthController do
  @moduledoc """
  Handles OAuth login flows (request, callback) and post-OAuth invite-code
  redemption.
  """

  use WaggerWeb, :controller

  plug Ueberauth

  def request(conn, _params) do
    # Ueberauth's plug above intercepts and redirects to the provider.
    # If we get here, the provider is unknown.
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(conn, _params) do
    # Filled in by later tasks.
    conn
    |> put_flash(:error, "Authentication not yet implemented.")
    |> redirect(to: ~p"/login")
  end
end
```

- [ ] **Step 3: Add a placeholder /login route to keep `~p"/login"` valid**

The `~p"/login"` sigil checks at compile time that the route exists. Add to the same scope, above the auth routes:

```elixir
    get "/login", SessionController, :new
    delete "/logout", SessionController, :delete
```

And create a minimal `lib/wagger_web/controllers/session_controller.ex`:

```elixir
defmodule WaggerWeb.SessionController do
  @moduledoc """
  Renders the login page and handles password-based sign-in and sign-out.
  Filled out across multiple tasks.
  """

  use WaggerWeb, :controller

  def new(conn, _params) do
    text(conn, "login page placeholder")
  end

  def delete(conn, _params) do
    conn |> clear_session() |> redirect(to: "/")
  end
end
```

- [ ] **Step 4: Compile and run all tests**

```bash
mix compile
mix test
```

Expected: compile clean, all existing tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/controllers/auth_controller.ex \
        lib/wagger_web/controllers/session_controller.ex \
        lib/wagger_web/router.ex
git commit -m "feat(auth): AuthController + SessionController stubs, /login + /auth routes (Task 15)"
```

### Task 16: AuthController.callback — full logic with stubbed `ueberauth_auth` assigns

**Files:**

- Modify: `lib/wagger_web/controllers/auth_controller.ex`
- Modify: `test/wagger_web/controllers/auth_controller_test.exs`
- Create: `lib/wagger_web/auth/oauth_payload.ex`

- [ ] **Step 1: Helper module to extract a normalized payload from `Ueberauth.Auth`**

Create `lib/wagger_web/auth/oauth_payload.ex`:

```elixir
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
    _ -> "{}"
  end
end
```

- [ ] **Step 2: Failing tests for callback**

Create `test/wagger_web/controllers/auth_controller_test.exs`:

```elixir
defmodule WaggerWeb.AuthControllerTest do
  @moduledoc """
  Tests AuthController.callback by injecting a synthetic
  `Ueberauth.Auth` struct into conn.assigns, bypassing real OAuth.
  """

  use WaggerWeb.ConnCase

  alias Wagger.Accounts
  alias Wagger.Invites
  alias Wagger.Repo

  setup do
    Application.put_env(:wagger, :bootstrap_admin_email, "boot@admin.example")
    on_exit(fn -> Application.delete_env(:wagger, :bootstrap_admin_email) end)
    :ok
  end

  defp google_auth(email, uid, opts \\ []) do
    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: email, name: "Test User"},
      extra: %Ueberauth.Auth.Extra{
        raw_info: %{"email_verified" => Keyword.get(opts, :verified, true)}
      },
      credentials: %Ueberauth.Auth.Credentials{}
    }
  end

  defp inject_auth(conn, auth) do
    Plug.Conn.assign(conn, :ueberauth_auth, auth)
  end

  describe "callback/2" do
    test "failure assigns redirect to /login with flash", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.assign(:ueberauth_failure, %Ueberauth.Failure{errors: []})
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/login"
      assert get_flash(conn, :error) =~ "couldn't sign in"
    end

    test "unverified email rejects with flash", %{conn: conn} do
      auth = google_auth("u@u.com", "u-1", verified: false)

      conn =
        conn
        |> inject_auth(auth)
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/login"
      assert get_flash(conn, :error) =~ "verified email"
    end

    test "existing identity logs the user in", %{conn: conn} do
      {:ok, user} = Accounts.register_oauth_user(%{email: "ret@x.com"})
      {:ok, _} = Accounts.link_identity(user, "google", %{provider_uid: "ret-1", email: "ret@x.com"})

      conn =
        conn
        |> inject_auth(google_auth("ret@x.com", "ret-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "matching email links new identity to existing user", %{conn: conn} do
      {:ok, user} = Accounts.register_oauth_user(%{email: "match@x.com"})

      conn =
        conn
        |> inject_auth(google_auth("match@x.com", "match-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert Accounts.find_user_by_identity("google", "match-1").id == user.id
    end

    test "bootstrap admin email creates admin user without invite", %{conn: conn} do
      conn =
        conn
        |> inject_auth(google_auth("boot@admin.example", "boot-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == "/"
      user = Repo.get_by(Wagger.Accounts.User, email: "boot@admin.example")
      assert user.role == "admin"
      assert user.invite_code_id == nil
    end

    test "new email redirects to invite prompt with pending session", %{conn: conn} do
      conn =
        conn
        |> inject_auth(google_auth("new@x.com", "new-1"))
        |> get(~p"/auth/google/callback")

      assert redirected_to(conn) == ~p"/auth/invite"
      assert %{"provider" => "google", "email" => "new@x.com"} =
               get_session(conn, :pending_oauth)
    end
  end
end
```

- [ ] **Step 3: Run to confirm failures**

```bash
mix test test/wagger_web/controllers/auth_controller_test.exs
```

Expected: failures across all six branches.

- [ ] **Step 4: Implement callback**

Replace `lib/wagger_web/controllers/auth_controller.ex`:

```elixir
defmodule WaggerWeb.AuthController do
  @moduledoc """
  Handles OAuth login flows (request, callback) and post-OAuth invite-code
  redemption.
  """

  use WaggerWeb, :controller

  alias Wagger.Accounts
  alias WaggerWeb.Auth.OauthPayload

  plug Ueberauth

  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_failure: _}} = conn, _params) do
    conn
    |> put_flash(:error, "We couldn't sign you in with that provider.")
    |> redirect(to: ~p"/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    payload = OauthPayload.from_auth(auth)
    handle_payload(conn, payload)
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "We couldn't sign you in with that provider.")
    |> redirect(to: ~p"/login")
  end

  defp handle_payload(conn, %{email_verified?: false}) do
    conn
    |> put_flash(:error, "Your provider must give us a verified email address.")
    |> redirect(to: ~p"/login")
  end

  defp handle_payload(conn, payload) do
    case Accounts.find_user_by_identity(payload.provider, payload.provider_uid) do
      %{} = user ->
        log_in(conn, user)

      nil ->
        case Accounts.get_user_by_email(payload.email) do
          %{} = user ->
            {:ok, _} =
              Accounts.link_identity(user, payload.provider, %{
                provider_uid: payload.provider_uid,
                email: payload.email,
                raw_info: payload.raw_info
              })

            log_in(conn, user)

          nil ->
            register_new_email(conn, payload)
        end
    end
  end

  defp register_new_email(conn, payload) do
    bootstrap = Application.get_env(:wagger, :bootstrap_admin_email)

    if is_binary(bootstrap) and bootstrap == payload.email do
      {:ok, user} =
        Accounts.register_oauth_user(%{
          email: payload.email,
          display_name: payload.display_name,
          role: "admin"
        })

      {:ok, _} =
        Accounts.link_identity(user, payload.provider, %{
          provider_uid: payload.provider_uid,
          email: payload.email,
          raw_info: payload.raw_info
        })

      log_in(conn, user)
    else
      conn
      |> put_session(:pending_oauth, %{
        "provider" => payload.provider,
        "provider_uid" => payload.provider_uid,
        "email" => payload.email,
        "display_name" => payload.display_name,
        "raw_info" => payload.raw_info
      })
      |> redirect(to: ~p"/auth/invite")
    end
  end

  defp log_in(conn, user) do
    return_to = get_session(conn, :return_to) || "/"

    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> delete_session(:pending_oauth)
    |> delete_session(:return_to)
    |> redirect(to: return_to)
  end

  defp renew_session(conn) do
    conn |> configure_session(renew: true) |> clear_session()
  end
end
```

The reference to `~p"/auth/invite"` will be valid once Task 17 adds the route. To compile in the meantime, add a temporary stub route at the same time as Task 17, or use a string `"/auth/invite"` here. To avoid the temporary stub, replace `~p"/auth/invite"` with `"/auth/invite"` for now and switch to the sigil after Task 17.

Actually: replace the two `~p"/auth/invite"` references with `"/auth/invite"` to keep compilation valid. Task 17 keeps it as a literal string; both work.

- [ ] **Step 5: Run tests**

```bash
mix test test/wagger_web/controllers/auth_controller_test.exs
```

Expected: all six pass. The `get_flash/2` helper is provided by `WaggerWeb.ConnCase` via `Phoenix.ConnTest`; if missing in your Phoenix version, replace with `Phoenix.Flash.get(conn.assigns.flash, :error)`.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/auth/ \
        lib/wagger_web/controllers/auth_controller.ex \
        test/wagger_web/controllers/auth_controller_test.exs
git commit -m "feat(auth): AuthController.callback — six branches (Task 16)"
```

### Task 17: Invite-code redemption — `/auth/invite` GET + POST

**Files:**

- Modify: `lib/wagger_web/router.ex`
- Modify: `lib/wagger_web/controllers/auth_controller.ex`
- Create: `lib/wagger_web/controllers/auth_html.ex`
- Create: `lib/wagger_web/controllers/auth_html/invite.html.heex`
- Modify: `test/wagger_web/controllers/auth_controller_test.exs`

- [ ] **Step 1: Add routes**

In `lib/wagger_web/router.ex`, inside the same browser scope, add:

```elixir
    get "/auth/invite", AuthController, :invite_form
    post "/auth/invite", AuthController, :invite_submit
```

- [ ] **Step 2: Failing tests for invite flow**

Append to `test/wagger_web/controllers/auth_controller_test.exs`:

```elixir
  describe "invite_form/2" do
    test "redirects to /login when no pending OAuth in session", %{conn: conn} do
      conn = get(conn, ~p"/auth/invite")
      assert redirected_to(conn) == ~p"/login"
    end

    test "renders the form when pending OAuth is in session", %{conn: conn} do
      conn =
        conn
        |> init_test_session(pending_oauth: %{
          "provider" => "google",
          "provider_uid" => "x",
          "email" => "x@y.com",
          "display_name" => "X",
          "raw_info" => "{}"
        })
        |> get(~p"/auth/invite")

      assert html_response(conn, 200) =~ "invite code"
    end
  end

  describe "invite_submit/2" do
    setup %{conn: conn} do
      conn =
        init_test_session(conn, pending_oauth: %{
          "provider" => "google",
          "provider_uid" => "p-1",
          "email" => "p@p.com",
          "display_name" => "P",
          "raw_info" => "{}"
        })

      {:ok, code} = Invites.create_code(%{label: "ok"})
      %{conn: conn, code: code}
    end

    test "valid code creates user, logs in, redirects to /", %{conn: conn, code: code} do
      conn = post(conn, ~p"/auth/invite", %{"code" => code.code})

      assert redirected_to(conn) == "/"
      assert is_integer(get_session(conn, :user_id))
      user = Wagger.Repo.get_by!(Wagger.Accounts.User, email: "p@p.com")
      assert user.invite_code_id == code.id
    end

    test "invalid code stays on page with flash", %{conn: conn} do
      conn = post(conn, ~p"/auth/invite", %{"code" => "bad-code"})
      assert html_response(conn, 200) =~ "invite code"
      assert get_flash(conn, :error) =~ "not recognized"
    end

    test "missing pending session redirects to /login", %{conn: _conn} do
      conn = post(build_conn(), ~p"/auth/invite", %{"code" => "anything"})
      assert redirected_to(conn) == ~p"/login"
    end
  end
```

(`init_test_session/2` comes from `Plug.Test`; ConnCase imports `Phoenix.ConnTest` which provides it.)

- [ ] **Step 3: Run to confirm failures**

```bash
mix test test/wagger_web/controllers/auth_controller_test.exs
```

Expected: new failures.

- [ ] **Step 4: Implement controller actions**

Append to `lib/wagger_web/controllers/auth_controller.ex` (inside the module, before the final `end`):

```elixir
  def invite_form(conn, _params) do
    case get_session(conn, :pending_oauth) do
      nil -> redirect(conn, to: ~p"/login")
      _ -> render(conn, :invite, layout: false)
    end
  end

  def invite_submit(conn, %{"code" => code}) do
    case get_session(conn, :pending_oauth) do
      nil ->
        redirect(conn, to: ~p"/login")

      payload ->
        case Wagger.Invites.redeem(code, %{
               provider: payload["provider"],
               provider_uid: payload["provider_uid"],
               email: payload["email"],
               display_name: payload["display_name"],
               raw_info: payload["raw_info"]
             }) do
          {:ok, user} ->
            log_in(conn, user)

          {:error, reason} ->
            conn
            |> put_flash(:error, invite_error_message(reason))
            |> render(:invite, layout: false)
        end
    end
  end

  defp invite_error_message(:not_found), do: "That invite code wasn't recognized."
  defp invite_error_message(:revoked), do: "That invite code has been revoked."
  defp invite_error_message(:expired), do: "That invite code has expired."
  defp invite_error_message(:exhausted), do: "That invite code has no uses left."
  defp invite_error_message(_), do: "That invite code can't be used."
```

- [ ] **Step 5: HTML view module**

Create `lib/wagger_web/controllers/auth_html.ex`:

```elixir
defmodule WaggerWeb.AuthHTML do
  @moduledoc false
  use WaggerWeb, :html

  embed_templates "auth_html/*"
end
```

- [ ] **Step 6: Invite template**

Create `lib/wagger_web/controllers/auth_html/invite.html.heex`:

```heex
<main class="mx-auto max-w-md px-4 py-12">
  <h1 class="text-2xl font-semibold">Enter your invite code</h1>
  <p class="text-sm text-gray-500 mt-2">
    Wagger needs an invite code to finish creating your account.
  </p>

  <.flash_group flash={@flash} />

  <form method="post" action={~p"/auth/invite"} class="mt-6 space-y-4">
    <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
    <input
      type="text"
      name="code"
      autofocus
      required
      class="w-full rounded border px-3 py-2"
      placeholder="invite code"
    />
    <button type="submit" class="w-full rounded bg-blue-600 px-4 py-2 text-white">
      Continue
    </button>
  </form>
</main>
```

- [ ] **Step 7: Wire AuthHTML into the controller**

In `lib/wagger_web/controllers/auth_controller.ex`, add at the top of the module body (right after `use WaggerWeb, :controller`):

```elixir
  alias WaggerWeb.AuthHTML
  plug :put_view, html: AuthHTML
```

Move the `plug Ueberauth` so it comes after `plug :put_view, ...`.

- [ ] **Step 8: Run tests**

```bash
mix test test/wagger_web/controllers/auth_controller_test.exs
```

Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add lib/wagger_web/controllers/ \
        lib/wagger_web/router.ex \
        test/wagger_web/controllers/auth_controller_test.exs
git commit -m "feat(auth): /auth/invite GET + POST with redemption (Task 17)"
```

---

## Phase 6 — Login page + SessionController

### Task 18: SessionController.create — password login

**Files:**

- Modify: `lib/wagger_web/controllers/session_controller.ex`
- Create: `lib/wagger_web/controllers/session_html.ex`
- Create: `lib/wagger_web/controllers/session_html/new.html.heex`
- Modify: `lib/wagger_web/router.ex`
- Create: `test/wagger_web/controllers/session_controller_test.exs`

- [ ] **Step 1: Add `post /login` route**

In `lib/wagger_web/router.ex`, inside the public browser scope, add:

```elixir
    post "/login", SessionController, :create
```

- [ ] **Step 2: Failing tests**

Create `test/wagger_web/controllers/session_controller_test.exs`:

```elixir
defmodule WaggerWeb.SessionControllerTest do
  use WaggerWeb.ConnCase

  alias Wagger.Accounts

  describe "new/2" do
    test "renders login page", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Sign in"
    end
  end

  describe "create/2" do
    setup do
      {:ok, user} = Accounts.register_oauth_user(%{email: "p@p.com"})
      {:ok, user} = Accounts.set_password(user, "long-enough-pass")
      %{user: user}
    end

    test "valid credentials log in and redirect", %{conn: conn, user: user} do
      conn = post(conn, ~p"/login", %{"email" => "p@p.com", "password" => "long-enough-pass"})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "invalid credentials stay on login page with flash", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"email" => "p@p.com", "password" => "wrong"})
      assert html_response(conn, 200) =~ "Sign in"
      assert get_flash(conn, :error) =~ "incorrect"
    end

    test "unknown user stays on login page (no info leak)", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"email" => "ghost@x.com", "password" => "anything-long"})
      assert html_response(conn, 200) =~ "Sign in"
      assert get_flash(conn, :error) =~ "incorrect"
    end
  end

  describe "delete/2" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> init_test_session(user_id: 123)
        |> delete(~p"/logout")

      assert redirected_to(conn) == ~p"/login"
      assert is_nil(get_session(conn, :user_id))
    end
  end
end
```

- [ ] **Step 3: Run to confirm failures**

```bash
mix test test/wagger_web/controllers/session_controller_test.exs
```

Expected: failures on missing template + missing create action.

- [ ] **Step 4: Implement SessionController**

Replace `lib/wagger_web/controllers/session_controller.ex`:

```elixir
defmodule WaggerWeb.SessionController do
  @moduledoc """
  Renders the login page and handles password sign-in and sign-out.
  """

  use WaggerWeb, :controller

  alias Wagger.Accounts
  alias Wagger.OauthCredentials
  alias WaggerWeb.SessionHTML

  plug :put_view, html: SessionHTML

  def new(conn, _params) do
    render(conn, :new,
      layout: false,
      providers: %{
        google: OauthCredentials.provider_configured?("google"),
        github: OauthCredentials.provider_configured?("github")
      }
    )
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_by_password(email, password) do
      {:ok, user} ->
        return_to = get_session(conn, :return_to) || "/"

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:user_id, user.id)
        |> redirect(to: return_to)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Email or password incorrect.")
        |> render(:new,
          layout: false,
          providers: %{
            google: OauthCredentials.provider_configured?("google"),
            github: OauthCredentials.provider_configured?("github")
          }
        )
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/login")
  end
end
```

- [ ] **Step 5: HTML view module + template**

Create `lib/wagger_web/controllers/session_html.ex`:

```elixir
defmodule WaggerWeb.SessionHTML do
  @moduledoc false
  use WaggerWeb, :html

  embed_templates "session_html/*"
end
```

Create `lib/wagger_web/controllers/session_html/new.html.heex`:

```heex
<main class="mx-auto max-w-md px-4 py-12">
  <h1 class="text-2xl font-semibold">Sign in</h1>

  <.flash_group flash={@flash} />

  <div class="mt-6 space-y-3">
    <a
      :if={@providers.google}
      href={~p"/auth/google"}
      class="flex w-full items-center justify-center rounded border px-4 py-2 hover:bg-gray-50"
    >
      Sign in with Google
    </a>
    <button :if={!@providers.google} disabled
      class="flex w-full items-center justify-center rounded border px-4 py-2 text-gray-400">
      Sign in with Google (not configured)
    </button>

    <a
      :if={@providers.github}
      href={~p"/auth/github"}
      class="flex w-full items-center justify-center rounded border px-4 py-2 hover:bg-gray-50"
    >
      Sign in with GitHub
    </a>
    <button :if={!@providers.github} disabled
      class="flex w-full items-center justify-center rounded border px-4 py-2 text-gray-400">
      Sign in with GitHub (not configured)
    </button>
  </div>

  <div class="my-6 text-center text-sm text-gray-500">or</div>

  <form method="post" action={~p"/login"} class="space-y-3">
    <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
    <input type="email" name="email" required placeholder="email"
      class="w-full rounded border px-3 py-2" />
    <input type="password" name="password" required placeholder="password"
      class="w-full rounded border px-3 py-2" />
    <button type="submit" class="w-full rounded bg-blue-600 px-4 py-2 text-white">
      Sign in with password
    </button>
  </form>
</main>
```

- [ ] **Step 6: Run tests**

```bash
mix test test/wagger_web/controllers/session_controller_test.exs
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/controllers/session_controller.ex \
        lib/wagger_web/controllers/session_html.ex \
        lib/wagger_web/controllers/session_html/ \
        lib/wagger_web/router.ex \
        test/wagger_web/controllers/session_controller_test.exs
git commit -m "feat(auth): SessionController — login page + password create + logout (Task 18)"
```

---

## Phase 7 — Plugs and route gating

### Task 19: `FetchCurrentUser` plug

**Files:**

- Create: `lib/wagger_web/plugs/fetch_current_user.ex`
- Create: `test/wagger_web/plugs/fetch_current_user_test.exs`
- Modify: `lib/wagger_web/router.ex`

- [ ] **Step 1: Failing test**

Create `test/wagger_web/plugs/fetch_current_user_test.exs`:

```elixir
defmodule WaggerWeb.Plugs.FetchCurrentUserTest do
  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.FetchCurrentUser

  test "assigns nil when no user_id in session" do
    conn = conn(:get, "/") |> init_test_session(%{}) |> FetchCurrentUser.call([])
    assert is_nil(conn.assigns[:current_user])
  end

  test "assigns the user when user_id is in session" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "fc@x.com"})

    conn =
      conn(:get, "/")
      |> init_test_session(%{"user_id" => user.id})
      |> FetchCurrentUser.call([])

    assert conn.assigns.current_user.id == user.id
  end

  test "assigns nil when session has stale user_id" do
    conn =
      conn(:get, "/")
      |> init_test_session(%{"user_id" => 999_999})
      |> FetchCurrentUser.call([])

    assert is_nil(conn.assigns[:current_user])
  end
end
```

- [ ] **Step 2: Implement**

Create `lib/wagger_web/plugs/fetch_current_user.ex`:

```elixir
defmodule WaggerWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Loads the current user (if any) from the session into `conn.assigns.current_user`.
  Never halts; assigns nil for missing or stale sessions.
  """

  import Plug.Conn

  alias Wagger.Repo
  alias Wagger.Accounts.User

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)
    user = user_id && Repo.get(User, user_id)
    assign(conn, :current_user, user)
  end
end
```

- [ ] **Step 3: Run test**

```bash
mix test test/wagger_web/plugs/fetch_current_user_test.exs
```

Expected: all pass.

- [ ] **Step 4: Wire into the `:browser` pipeline**

In `lib/wagger_web/router.ex`, inside the `pipeline :browser do ... end` block, add at the end:

```elixir
    plug WaggerWeb.Plugs.FetchCurrentUser
```

- [ ] **Step 5: Run all tests**

```bash
mix test
```

Expected: all pass. Existing controller tests don't depend on `:current_user` being absent, so adding this plug as a no-op (when no session) is safe.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/plugs/fetch_current_user.ex \
        test/wagger_web/plugs/fetch_current_user_test.exs \
        lib/wagger_web/router.ex
git commit -m "feat(auth): FetchCurrentUser plug + browser pipeline wire-in (Task 19)"
```

### Task 20: `RequireUser` and `RequireAdmin` plugs

**Files:**

- Create: `lib/wagger_web/plugs/require_user.ex`
- Create: `lib/wagger_web/plugs/require_admin.ex`
- Create: `test/wagger_web/plugs/require_user_test.exs`
- Create: `test/wagger_web/plugs/require_admin_test.exs`

- [ ] **Step 1: Failing test for RequireUser**

Create `test/wagger_web/plugs/require_user_test.exs`:

```elixir
defmodule WaggerWeb.Plugs.RequireUserTest do
  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.RequireUser

  test "passes when current_user is assigned" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "r@r.com"})

    conn =
      conn(:get, "/applications")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireUser.call([])

    refute conn.halted
  end

  test "redirects to /login and stashes return_to when no current_user" do
    conn =
      conn(:get, "/applications")
      |> init_test_session(%{})
      |> assign(:current_user, nil)
      |> RequireUser.call([])

    assert conn.halted
    assert conn.status == 302
    assert get_session(conn, :return_to) == "/applications"
  end
end
```

- [ ] **Step 2: Implement RequireUser**

Create `lib/wagger_web/plugs/require_user.ex`:

```elixir
defmodule WaggerWeb.Plugs.RequireUser do
  @moduledoc """
  Halts the request with a redirect to /login when no `:current_user` is
  assigned. Stashes the requested path in session under `:return_to` so
  the post-login flow can return there.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2, put_flash: 3]

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    return_to = conn.request_path <> if conn.query_string == "", do: "", else: "?" <> conn.query_string

    conn
    |> put_session(:return_to, return_to)
    |> put_flash(:error, "You need to sign in to access that.")
    |> redirect(to: "/login")
    |> halt()
  end
end
```

- [ ] **Step 3: Run test**

```bash
mix test test/wagger_web/plugs/require_user_test.exs
```

Expected: pass.

- [ ] **Step 4: Failing test for RequireAdmin**

Create `test/wagger_web/plugs/require_admin_test.exs`:

```elixir
defmodule WaggerWeb.Plugs.RequireAdminTest do
  use Wagger.DataCase

  import Plug.Test
  import Plug.Conn

  alias Wagger.Accounts
  alias WaggerWeb.Plugs.RequireAdmin

  test "passes when current_user is admin" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "a@a.com", role: "admin"})

    conn =
      conn(:get, "/admin/invites")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireAdmin.call([])

    refute conn.halted
  end

  test "renders 403 when current_user is not admin" do
    {:ok, user} = Accounts.register_oauth_user(%{email: "u@u.com"})

    conn =
      conn(:get, "/admin/invites")
      |> init_test_session(%{})
      |> assign(:current_user, user)
      |> RequireAdmin.call([])

    assert conn.halted
    assert conn.status == 403
  end
end
```

- [ ] **Step 5: Implement RequireAdmin**

Create `lib/wagger_web/plugs/require_admin.ex`:

```elixir
defmodule WaggerWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts with a 403 plain-text response when `:current_user` is not an
  admin. Assumes RequireUser has already run; if `current_user` is nil
  we still emit 403 (don't redirect — admin pages shouldn't bounce
  logged-in non-admins).
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{role: "admin"}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(403, "Forbidden")
    |> halt()
  end
end
```

- [ ] **Step 6: Run test**

```bash
mix test test/wagger_web/plugs/require_admin_test.exs
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/plugs/require_user.ex \
        lib/wagger_web/plugs/require_admin.ex \
        test/wagger_web/plugs/require_user_test.exs \
        test/wagger_web/plugs/require_admin_test.exs
git commit -m "feat(auth): RequireUser + RequireAdmin plugs (Task 20)"
```

### Task 21: `AuthHook` for LiveView mount + router restructure

**Files:**

- Create: `lib/wagger_web/hooks/auth_hook.ex`
- Modify: `lib/wagger_web/router.ex`

- [ ] **Step 1: Implement the LiveView hook**

Create `lib/wagger_web/hooks/auth_hook.ex`:

```elixir
defmodule WaggerWeb.Hooks.AuthHook do
  @moduledoc """
  on_mount hooks that load the current user (and optionally enforce
  admin role) for LiveViews.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2, put_flash: 3]

  alias Wagger.Repo
  alias Wagger.Accounts.User

  def on_mount(:require_user, _params, %{"user_id" => user_id}, socket) when is_integer(user_id) do
    case Repo.get(User, user_id) do
      nil -> halt_to_login(socket)
      %User{} = user -> {:cont, assign(socket, :current_user, user)}
    end
  end

  def on_mount(:require_user, _params, _session, socket) do
    halt_to_login(socket)
  end

  def on_mount(:require_admin, params, session, socket) do
    case on_mount(:require_user, params, session, socket) do
      {:cont, socket} ->
        if socket.assigns.current_user.role == "admin" do
          {:cont, socket}
        else
          {:halt, socket |> put_flash(:error, "Admin access required.") |> redirect(to: "/")}
        end

      halt ->
        halt
    end
  end

  defp halt_to_login(socket) do
    {:halt, socket |> put_flash(:error, "You need to sign in.") |> redirect(to: "/login")}
  end
end
```

- [ ] **Step 2: Restructure the router scopes**

Replace `lib/wagger_web/router.ex` entirely:

```elixir
defmodule WaggerWeb.Router do
  @moduledoc false
  use WaggerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WaggerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug WaggerWeb.Plugs.FetchCurrentUser
  end

  pipeline :authenticated do
    plug WaggerWeb.Plugs.RequireUser
  end

  pipeline :admin do
    plug WaggerWeb.Plugs.RequireAdmin
  end

  pipeline :api do
    plug :accepts, ["json", "edn"]
    plug WaggerWeb.Plugs.ApiVersion
    plug WaggerWeb.Plugs.Authenticate
  end

  # --- Public surface ---
  scope "/", WaggerWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    get "/auth/invite", AuthController, :invite_form
    post "/auth/invite", AuthController, :invite_submit
    get "/auth/:provider", AuthController, :request
    get "/auth/:provider/callback", AuthController, :callback
  end

  # --- Authenticated browser/LiveView ---
  scope "/", WaggerWeb do
    pipe_through [:browser, :authenticated]

    live_session :default,
      on_mount: [
        {WaggerWeb.Hooks.AuthHook, :require_user},
        {WaggerWeb.Hooks.NavHook, :default}
      ] do
      live "/", DashboardLive, :index
      live "/applications", AppListLive, :index
      live "/applications/:id", AppDetailLive, :show
      live "/users", UserLive, :index
      live "/mcp", McpGeneratorLive, :index
    end

    live_session :hub,
      on_mount: [
        {WaggerWeb.Hooks.AuthHook, :require_user},
        {WaggerWeb.Hooks.NavHook, :default}
      ] do
      live "/hub", HubListLive, :index
      live "/hub/:name", HubDetailLive, :show
    end

    get "/mcp/download/:token", McpDownloadController, :show
  end

  # --- Admin ---
  scope "/admin", WaggerWeb do
    pipe_through [:browser, :authenticated, :admin]

    live_session :admin,
      on_mount: [
        {WaggerWeb.Hooks.AuthHook, :require_admin},
        {WaggerWeb.Hooks.NavHook, :default}
      ] do
      live "/invites", InviteCodeLive, :index
      live "/oauth", OauthCredentialsLive, :index
    end
  end

  # --- API ---
  scope "/api", WaggerWeb do
    pipe_through :api

    resources "/applications", ApplicationController, except: [:new, :edit] do
      resources "/routes", RouteController, except: [:new, :edit]
    end

    get "/applications/:application_id/export", ExportController, :show
    get "/applications/:application_id/lookup", LookupController, :show

    post "/applications/:application_id/import/bulk", ImportController, :bulk
    post "/applications/:application_id/import/openapi", ImportController, :openapi
    post "/applications/:application_id/import/accesslog", ImportController, :accesslog
    post "/applications/:application_id/import/confirm", ImportController, :confirm

    post "/applications/:application_id/generate/:provider", GenerateController, :create

    get "/applications/:application_id/snapshots", SnapshotController, :index
    get "/applications/:application_id/snapshots/:id", SnapshotController, :show
    get "/applications/:application_id/drift/:provider", DriftController, :show
  end
end
```

(The `InviteCodeLive` and `OauthCredentialsLive` references will fail to compile until Tasks 22 and 23. To allow incremental compile, create empty stub modules now:)

Create `lib/wagger_web/live/invite_code_live.ex`:

```elixir
defmodule WaggerWeb.InviteCodeLive do
  @moduledoc false
  use WaggerWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H"<div>Invite codes (stub)</div>"
end
```

Create `lib/wagger_web/live/oauth_credentials_live.ex`:

```elixir
defmodule WaggerWeb.OauthCredentialsLive do
  @moduledoc false
  use WaggerWeb, :live_view

  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H"<div>OAuth credentials (stub)</div>"
end
```

- [ ] **Step 3: Run all tests**

```bash
mix test
```

Expected: many existing LiveView tests will FAIL because they don't pass a session, so unauthenticated mounts now redirect. Tasks 22+ will fix them by setting up authenticated LiveView tests; for now, skip the failing existing LiveView tests by adding `@moduletag :skip_for_auth_rollout` and setting up a global skip — OR, easier, fix them inline now with a helper.

Choose the inline-fix approach. Edit each LiveView test file to add a setup that injects a logged-in user, and mount with that session. Add a helper to `test/support/conn_case.ex`:

In `test/support/conn_case.ex`, inside the `using do quote do ... end`, append before the closing `end end`:

```elixir
      def log_in_as(conn, user) do
        Plug.Test.init_test_session(conn, user_id: user.id)
      end

      def log_in_as_admin(conn) do
        {:ok, user} = Wagger.Accounts.register_oauth_user(%{
          email: "admin#{System.unique_integer([:positive])}@x.com",
          role: "admin"
        })
        log_in_as(conn, user)
      end

      def log_in_as_user(conn) do
        {:ok, user} = Wagger.Accounts.register_oauth_user(%{
          email: "user#{System.unique_integer([:positive])}@x.com"
        })
        log_in_as(conn, user)
      end
```

Now go through each failing test file in `test/wagger_web/live/` and `test/wagger_web/controllers/` and add `setup :authenticate_browser_tests` at the top of each describe block, OR add a single line at the start of each test that needs auth: `conn = log_in_as_user(conn)`.

For `test/wagger_web/live/dashboard_live_test.exs`, `app_detail_live_test.exs`, `mcp_generator_live_test.exs`, `user_live_test.exs`: at the top of each test that does `live(conn, ~p"/...")`, prepend `conn = log_in_as_user(conn)`.

For controller tests in `test/wagger_web/controllers/` (those that aren't AuthController/SessionController): prepend `conn = log_in_as_user(conn)` to each test that hits a now-authenticated browser route. The controllers under test (`/api/...`) are in the `:api` scope and unaffected.

Audit:

- `application_controller_test.exs` — `/api/...` routes, unchanged.
- `drift_controller_test.exs` — `/api/...`, unchanged.
- `error_html_test.exs` — error rendering, unchanged.
- `error_json_test.exs` — error rendering, unchanged.
- `export_controller_test.exs` — `/api/...`, unchanged.
- `generate_controller_test.exs` — `/api/...`, unchanged.
- `import_controller_test.exs` — `/api/...`, unchanged.
- `lookup_controller_test.exs` — `/api/...`, unchanged.
- `mcp_download_controller_test.exs` — `/mcp/download/:token` is now in the authenticated scope. Update each test: `conn = log_in_as_user(conn)`.
- `route_controller_test.exs` — `/api/...`, unchanged.
- `snapshot_controller_test.exs` — `/api/...`, unchanged.

LiveView tests all need `log_in_as_user` calls.

- [ ] **Step 4: Run tests until green**

```bash
mix test
```

Expected: all pass after the audit edits.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/hooks/auth_hook.ex \
        lib/wagger_web/live/invite_code_live.ex \
        lib/wagger_web/live/oauth_credentials_live.ex \
        lib/wagger_web/router.ex \
        test/support/conn_case.ex \
        test/
git commit -m "feat(auth): AuthHook + router scope restructure + auth helpers (Task 21)"
```

---

## Phase 8 — Admin UI

### Task 22: `InviteCodeLive` — full implementation

**Files:**

- Modify: `lib/wagger_web/live/invite_code_live.ex`
- Create: `lib/wagger_web/live/invite_code_live.html.heex`
- Create: `test/wagger_web/live/invite_code_live_test.exs`

- [ ] **Step 1: Failing test**

Create `test/wagger_web/live/invite_code_live_test.exs`:

```elixir
defmodule WaggerWeb.InviteCodeLiveTest do
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.Invites

  describe "as admin" do
    setup %{conn: conn} do
      conn = log_in_as_admin(conn)
      %{conn: conn}
    end

    test "lists existing codes", %{conn: conn} do
      {:ok, _} = Invites.create_code(%{label: "test-1"})

      {:ok, _view, html} = live(conn, ~p"/admin/invites")
      assert html =~ "test-1"
    end

    test "creates a new code via form submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/invites")

      view
      |> form("#new-code-form", invite: %{label: "fresh"})
      |> render_submit()

      assert render(view) =~ "fresh"
    end

    test "revoke action revokes the code", %{conn: conn} do
      {:ok, code} = Invites.create_code(%{label: "rev"})

      {:ok, view, _html} = live(conn, ~p"/admin/invites")
      view |> element("button[phx-click=revoke][phx-value-id=#{code.id}]") |> render_click()

      assert render(view) =~ "revoked"
    end
  end

  describe "as non-admin" do
    test "renders 403 / redirects", %{conn: conn} do
      conn = log_in_as_user(conn)
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/invites")
    end
  end

  describe "unauthenticated" do
    test "redirects to /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/admin/invites")
    end
  end
end
```

- [ ] **Step 2: Implement LiveView**

Replace `lib/wagger_web/live/invite_code_live.ex`:

```elixir
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
  defp parse_int(s), do: case Integer.parse(s) do
                          {n, _} -> n
                          _ -> nil
                        end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
```

- [ ] **Step 3: Template**

Create `lib/wagger_web/live/invite_code_live.html.heex`:

```heex
<main class="mx-auto max-w-4xl px-4 py-8">
  <h1 class="text-2xl font-semibold">Invite codes</h1>

  <.flash_group flash={@flash} />

  <div :if={@new_code_revealed} class="mt-4 rounded border border-green-300 bg-green-50 p-3">
    <p class="text-sm font-medium">New code:</p>
    <code class="font-mono"><%= @new_code_revealed %></code>
  </div>

  <form id="new-code-form" phx-submit="create" class="mt-6 grid grid-cols-3 gap-3 items-end">
    <div>
      <label class="text-sm">Label</label>
      <input name="invite[label]" class="w-full rounded border px-2 py-1" />
    </div>
    <div>
      <label class="text-sm">Max uses</label>
      <input type="number" name="invite[max_uses]" class="w-full rounded border px-2 py-1" />
    </div>
    <div>
      <label class="text-sm">Expires (ISO 8601)</label>
      <input name="invite[expires_at]" placeholder="2099-01-01T00:00:00Z"
        class="w-full rounded border px-2 py-1" />
    </div>
    <button type="submit" class="col-span-3 rounded bg-blue-600 px-4 py-2 text-white">
      Generate code
    </button>
  </form>

  <table class="mt-8 w-full text-sm">
    <thead class="text-left">
      <tr>
        <th class="py-2">Code</th>
        <th>Label</th>
        <th>Status</th>
        <th>Uses</th>
        <th>Expires</th>
        <th></th>
      </tr>
    </thead>
    <tbody>
      <tr :for={c <- @codes} class="border-t">
        <td class="py-2 font-mono"><%= c.code %></td>
        <td><%= c.label %></td>
        <td><%= c.status %></td>
        <td><%= c.uses_count %><%= if c.max_uses, do: "/" <> Integer.to_string(c.max_uses) %></td>
        <td><%= c.expires_at %></td>
        <td>
          <button :if={c.status == :active}
            phx-click="revoke" phx-value-id={c.id}
            class="text-red-600 hover:underline">Revoke</button>
        </td>
      </tr>
    </tbody>
  </table>
</main>
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger_web/live/invite_code_live_test.exs
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/live/invite_code_live.ex \
        lib/wagger_web/live/invite_code_live.html.heex \
        test/wagger_web/live/invite_code_live_test.exs
git commit -m "feat(auth): InviteCodeLive — list/create/revoke (Task 22)"
```

### Task 23: `OauthCredentialsLive` — admin OAuth credentials UI

**Files:**

- Modify: `lib/wagger_web/live/oauth_credentials_live.ex`
- Create: `lib/wagger_web/live/oauth_credentials_live.html.heex`
- Create: `test/wagger_web/live/oauth_credentials_live_test.exs`

- [ ] **Step 1: Failing test**

Create `test/wagger_web/live/oauth_credentials_live_test.exs`:

```elixir
defmodule WaggerWeb.OauthCredentialsLiveTest do
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.OauthCredentials

  setup %{conn: conn} do
    conn = log_in_as_admin(conn)
    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)
    end)
    %{conn: conn}
  end

  test "shows masked secret when credentials exist", %{conn: conn} do
    {:ok, _} = OauthCredentials.upsert("google", "id-x", "secret-x")

    {:ok, _view, html} = live(conn, ~p"/admin/oauth")
    assert html =~ "id-x"
    assert html =~ "••••"
    refute html =~ "secret-x"
  end

  test "saves new credentials via form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/oauth")

    view
    |> form("#cred-form-google", cred: %{client_id: "fresh-id", client_secret: "fresh-secret"})
    |> render_submit()

    assert {:ok, %{client_id: "fresh-id", client_secret: "fresh-secret"}} =
             OauthCredentials.get("google")
  end
end
```

- [ ] **Step 2: Implement**

Replace `lib/wagger_web/live/oauth_credentials_live.ex`:

```elixir
defmodule WaggerWeb.OauthCredentialsLive do
  @moduledoc """
  Admin LiveView for managing OAuth provider credentials. Secrets are
  shown as `••••` once set; saving locks the value via Wagger.Secrets.
  """

  use WaggerWeb, :live_view

  alias Wagger.OauthCredentials

  @providers ~w(google github)

  def mount(_params, _session, socket) do
    {:ok, assign(socket, :providers, providers_state())}
  end

  def handle_event("save", %{"provider" => provider, "cred" => params}, socket) do
    case OauthCredentials.upsert(provider, params["client_id"], params["client_secret"]) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{provider} credentials.")
         |> assign(:providers, providers_state())}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to save credentials.")}
    end
  end

  defp providers_state do
    Enum.map(@providers, fn p ->
      case OauthCredentials.get(p) do
        {:ok, %{client_id: id}} -> %{provider: p, client_id: id, has_secret: true}
        :error -> %{provider: p, client_id: "", has_secret: false}
      end
    end)
  end
end
```

- [ ] **Step 3: Template**

Create `lib/wagger_web/live/oauth_credentials_live.html.heex`:

```heex
<main class="mx-auto max-w-2xl px-4 py-8">
  <h1 class="text-2xl font-semibold">OAuth credentials</h1>

  <.flash_group flash={@flash} />

  <section :for={p <- @providers} class="mt-6 border rounded p-4">
    <h2 class="text-lg font-medium capitalize"><%= p.provider %></h2>

    <form id={"cred-form-#{p.provider}"} phx-submit="save" class="mt-3 space-y-3">
      <input type="hidden" name="provider" value={p.provider} />

      <div>
        <label class="text-sm">Client ID</label>
        <input name="cred[client_id]" value={p.client_id}
          class="w-full rounded border px-2 py-1" />
      </div>

      <div>
        <label class="text-sm">Client secret</label>
        <input
          name="cred[client_secret]"
          type="password"
          placeholder={if p.has_secret, do: "••••", else: "(unset)"}
          class="w-full rounded border px-2 py-1"
        />
        <p :if={p.has_secret} class="text-xs text-gray-500 mt-1">
          Leave blank to keep the existing secret; type a new value to replace it.
        </p>
      </div>

      <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-white">Save</button>
    </form>
  </section>
</main>
```

The "leave blank to keep" semantics requires that empty client_secret falls back to the existing locked value. Update the controller's `handle_event` to handle this:

Replace the `handle_event` clause:

```elixir
  def handle_event("save", %{"provider" => provider, "cred" => params}, socket) do
    secret = effective_secret(provider, params["client_secret"])

    case secret do
      :unset ->
        {:noreply,
         put_flash(socket, :error, "No secret has ever been set; please provide one.")}

      val ->
        case OauthCredentials.upsert(provider, params["client_id"], val) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Saved #{provider} credentials.")
             |> assign(:providers, providers_state())}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to save credentials.")}
        end
    end
  end

  defp effective_secret(provider, "") do
    case OauthCredentials.get(provider) do
      {:ok, %{client_secret: existing}} -> existing
      :error -> :unset
    end
  end

  defp effective_secret(_provider, secret), do: secret
```

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger_web/live/oauth_credentials_live_test.exs
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger_web/live/oauth_credentials_live.ex \
        lib/wagger_web/live/oauth_credentials_live.html.heex \
        test/wagger_web/live/oauth_credentials_live_test.exs
git commit -m "feat(auth): OauthCredentialsLive — admin manages provider creds (Task 23)"
```

### Task 24: Admin nav link

**Files:**

- Modify: `lib/wagger_web/components/layouts/app.html.heex` (or wherever the nav is rendered)
- Modify: `lib/wagger_web/hooks/nav_hook.ex`

- [ ] **Step 1: Inspect the existing nav**

```bash
grep -nE "nav|Admin|hub" lib/wagger_web/components/layouts/app.html.heex
```

Expected: see where the existing nav links live.

- [ ] **Step 2: Add admin nav conditionally**

In `lib/wagger_web/components/layouts/app.html.heex`, find the existing nav link list and add (only renders when current_user is admin — current_user is in conn.assigns from the FetchCurrentUser plug, propagated through the layout):

```heex
<.link :if={@current_user && @current_user.role == "admin"} href={~p"/admin/invites"}>Admin</.link>
```

If the existing layout uses `assigns[:current_user]` differently, mirror that. The key is the conditional `:if` based on role.

- [ ] **Step 3: Run all tests**

```bash
mix test
```

Expected: all pass. The layout must tolerate `@current_user` being nil (covered by the `:if` guard).

- [ ] **Step 4: Commit**

```bash
git add lib/wagger_web/components/
git commit -m "feat(auth): admin nav link visible only to admins (Task 24)"
```

---

## Phase 9 — Account settings

### Task 25: `AccountLive` — show identities, set/remove password, unlink identity

**Files:**

- Create: `lib/wagger_web/live/account_live.ex`
- Create: `lib/wagger_web/live/account_live.html.heex`
- Modify: `lib/wagger_web/router.ex`
- Create: `test/wagger_web/live/account_live_test.exs`

- [ ] **Step 1: Add route**

In `lib/wagger_web/router.ex`, inside the authenticated `:default` live_session, add:

```elixir
      live "/account", AccountLive, :show
```

- [ ] **Step 2: Failing test**

Create `test/wagger_web/live/account_live_test.exs`:

```elixir
defmodule WaggerWeb.AccountLiveTest do
  use WaggerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Wagger.Accounts

  setup %{conn: conn} do
    {:ok, user} = Accounts.register_oauth_user(%{email: "me@me.com"})
    {:ok, _} = Accounts.link_identity(user, "google", %{provider_uid: "g-1", email: "me@me.com"})
    conn = log_in_as(conn, user)
    %{conn: conn, user: user}
  end

  test "lists linked identities", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/account")
    assert html =~ "google"
  end

  test "set password persists a hashed password", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/account")

    view
    |> form("#password-form", password: %{value: "long-enough-password"})
    |> render_submit()

    reloaded = Wagger.Repo.get!(Wagger.Accounts.User, user.id)
    refute is_nil(reloaded.password_hash)
  end

  test "unlink identity refuses if it would orphan the account", %{conn: conn, user: user} do
    identity = Wagger.Repo.get_by!(Wagger.Accounts.OauthIdentity, user_id: user.id)

    {:ok, view, _html} = live(conn, ~p"/account")
    html = view |> element("button[phx-click=unlink][phx-value-id=#{identity.id}]") |> render_click()
    assert html =~ "no way to log in"
  end

  test "unlink identity succeeds when password is also set", %{conn: conn, user: user} do
    {:ok, _} = Accounts.set_password(user, "long-enough-password")

    identity = Wagger.Repo.get_by!(Wagger.Accounts.OauthIdentity, user_id: user.id)

    {:ok, view, _html} = live(conn, ~p"/account")
    view |> element("button[phx-click=unlink][phx-value-id=#{identity.id}]") |> render_click()

    assert is_nil(Wagger.Repo.get(Wagger.Accounts.OauthIdentity, identity.id))
  end
end
```

- [ ] **Step 3: Implement LiveView**

Create `lib/wagger_web/live/account_live.ex`:

```elixir
defmodule WaggerWeb.AccountLive do
  @moduledoc "Self-service account settings: identities, password."

  use WaggerWeb, :live_view

  alias Wagger.Accounts
  alias Wagger.Accounts.OauthIdentity
  alias Wagger.Repo

  import Ecto.Query

  def mount(_params, _session, socket) do
    {:ok, assign_state(socket)}
  end

  def handle_event("set_password", %{"password" => %{"value" => v}}, socket) do
    case Accounts.set_password(socket.assigns.current_user, v) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Password set.") |> assign_state()}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Password must be at least 12 characters.")}
    end
  end

  def handle_event("clear_password", _params, socket) do
    case Accounts.clear_password(socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Password removed.") |> assign_state()}

      {:error, %{message: msg}} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("unlink", %{"id" => id}, socket) do
    case Accounts.unlink_identity(socket.assigns.current_user, String.to_integer(id)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Identity unlinked.") |> assign_state()}

      {:error, %{message: msg}} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  defp assign_state(socket) do
    user = Repo.get!(Wagger.Accounts.User, socket.assigns.current_user.id)
    identities = Repo.all(from i in OauthIdentity, where: i.user_id == ^user.id)

    socket
    |> assign(:current_user, user)
    |> assign(:identities, identities)
    |> assign(:has_password, not is_nil(user.password_hash))
  end
end
```

- [ ] **Step 4: Template**

Create `lib/wagger_web/live/account_live.html.heex`:

```heex
<main class="mx-auto max-w-2xl px-4 py-8">
  <h1 class="text-2xl font-semibold">Account</h1>

  <.flash_group flash={@flash} />

  <section class="mt-6">
    <h2 class="text-lg font-medium">Email</h2>
    <p class="font-mono"><%= @current_user.email %></p>
  </section>

  <section class="mt-6">
    <h2 class="text-lg font-medium">Linked identities</h2>
    <ul class="mt-2 space-y-2">
      <li :for={i <- @identities} class="flex items-center justify-between border rounded p-2">
        <span><%= i.provider %> — <span class="font-mono text-sm"><%= i.email %></span></span>
        <button phx-click="unlink" phx-value-id={i.id}
          class="text-red-600 hover:underline">Unlink</button>
      </li>
    </ul>
  </section>

  <section class="mt-8">
    <h2 class="text-lg font-medium">Password</h2>

    <form id="password-form" phx-submit="set_password" class="mt-2 flex gap-2">
      <input type="password" name="password[value]" minlength="12"
        class="rounded border px-2 py-1 flex-1"
        placeholder={if @has_password, do: "Change password", else: "Set password"} />
      <button type="submit" class="rounded bg-blue-600 px-4 py-2 text-white">
        <%= if @has_password, do: "Change", else: "Set" %>
      </button>
    </form>

    <button :if={@has_password} phx-click="clear_password"
      class="mt-2 text-sm text-red-600 hover:underline">
      Remove password
    </button>
  </section>
</main>
```

- [ ] **Step 5: Run tests**

```bash
mix test test/wagger_web/live/account_live_test.exs
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/live/account_live.ex \
        lib/wagger_web/live/account_live.html.heex \
        lib/wagger_web/router.ex \
        test/wagger_web/live/account_live_test.exs
git commit -m "feat(auth): AccountLive — identities + password management (Task 25)"
```

---

## Phase 10 — Boot integration + runtime config

### Task 26: Boot-time `OauthCredentials.load_into_app_env`

**Files:**

- Modify: `lib/wagger/application.ex`

- [ ] **Step 1: Inspect the application supervisor**

```bash
cat lib/wagger/application.ex
```

Expected: a standard Phoenix application module with a `start/2` function that lists children including `Wagger.Repo` and `WaggerWeb.Endpoint`.

- [ ] **Step 2: Insert load call between Repo start and Endpoint**

In `lib/wagger/application.ex`'s `start/2`, after the Supervisor.start_link call (or after children are started), call `Wagger.OauthCredentials.load_into_app_env/0`. The cleanest pattern: split start into two phases — start Repo, then load credentials, then start Endpoint.

If the existing children list looks like:

```elixir
children = [
  WaggerWeb.Telemetry,
  Wagger.Repo,
  {DNSCluster, query: Application.get_env(:wagger, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Wagger.PubSub},
  WaggerWeb.Endpoint
]
```

Replace with:

```elixir
children = [
  WaggerWeb.Telemetry,
  Wagger.Repo,
  {DNSCluster, query: Application.get_env(:wagger, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: Wagger.PubSub},
  {Task, fn -> Wagger.OauthCredentials.load_into_app_env() end},
  WaggerWeb.Endpoint
]
```

The Task child runs once after Repo is up and exits; the Endpoint starts after, by which time Application env is populated.

- [ ] **Step 3: Run all tests**

```bash
mix test
```

Expected: all pass. Tests do not boot the full application supervision tree; this change only affects production/dev boot.

- [ ] **Step 4: Smoke-test in dev**

```bash
mix phx.server
```

Visit `http://localhost:4000/login` — observe that the Google/GitHub buttons are disabled with "(not configured)" until creds are added in the admin UI.

Press `Ctrl-C` twice to stop.

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/application.ex
git commit -m "feat(auth): load OAuth creds into Application env at boot (Task 26)"
```

### Task 27: `runtime.exs` reads `WAGGER_BOOTSTRAP_ADMIN_EMAIL`

**Files:**

- Modify: `config/runtime.exs`

- [ ] **Step 1: Inspect runtime.exs**

```bash
cat config/runtime.exs
```

- [ ] **Step 2: Add bootstrap admin email config**

Append to `config/runtime.exs` (it should run for all environments, but only when env var is set):

```elixir
if email = System.get_env("WAGGER_BOOTSTRAP_ADMIN_EMAIL") do
  config :wagger, :bootstrap_admin_email, email
end
```

- [ ] **Step 3: Run tests**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs
git commit -m "feat(auth): runtime.exs reads WAGGER_BOOTSTRAP_ADMIN_EMAIL (Task 27)"
```

### Task 28: Encryption round-trip integration test

**Files:**

- Create: `test/wagger/oauth_credentials_roundtrip_test.exs`

- [ ] **Step 1: Test**

Create `test/wagger/oauth_credentials_roundtrip_test.exs`:

```elixir
defmodule Wagger.OauthCredentialsRoundtripTest do
  @moduledoc """
  Integration test for the encrypt-at-rest contract: a credential persisted
  via Wagger.Secrets must come back identical after load_into_app_env/0
  publishes it into the Application env.
  """

  use Wagger.DataCase

  alias Wagger.OauthCredentials

  setup do
    on_exit(fn ->
      Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    end)
    :ok
  end

  test "persisted secret round-trips through Wagger.Secrets and into app env" do
    plain_secret = "rotation-token-#{System.unique_integer()}"
    {:ok, _} = OauthCredentials.upsert("google", "round-trip-id", plain_secret)

    Application.delete_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    :ok = OauthCredentials.load_into_app_env()

    cfg = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth)
    assert cfg[:client_id] == "round-trip-id"
    assert cfg[:client_secret] == plain_secret
  end
end
```

- [ ] **Step 2: Run**

```bash
mix test test/wagger/oauth_credentials_roundtrip_test.exs
```

Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add test/wagger/oauth_credentials_roundtrip_test.exs
git commit -m "test(auth): credential encryption round-trip (Task 28)"
```

---

## Final task: Full test sweep + documentation update

### Task 29: Final verification

- [ ] **Step 1: Full test run**

```bash
mix test
```

Expected: all tests pass. If any pre-existing tests still fail, investigate and fix individually before continuing.

- [ ] **Step 2: Compile cleanly with warnings as errors**

```bash
mix compile --warnings-as-errors
```

Expected: clean compile.

- [ ] **Step 3: Update README briefly**

In `README.md`, in the operations/setup section, add a short "Authentication" subsection:

```markdown
## Authentication

The browser/LiveView surface is gated behind login. Users sign in via
Google OAuth, GitHub OAuth, or local password (after first OAuth login).
First-time access is bootstrapped via `WAGGER_BOOTSTRAP_ADMIN_EMAIL`:
the OAuth login matching this email is auto-promoted to admin and
bypasses the invite-code gate.

OAuth provider credentials live encrypted in the database (via
`Wagger.Secrets`). For first-time bootstrap, set the env vars
`GOOGLE_OAUTH_CLIENT_ID`/`SECRET` and/or `GITHUB_OAUTH_CLIENT_ID`/`SECRET`;
they will be read on boot, stored encrypted, and the env vars can then be
removed from the deploy. Subsequent rotation happens via the admin UI at
`/admin/oauth`.

Invite codes (admin UI at `/admin/invites`) gate new-user registration.
The API path remains on its existing Bearer-API-key authentication.
```

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(auth): document OAuth + invite + bootstrap flow (Task 29)"
```

- [ ] **Step 5: Branch summary**

```bash
git log --oneline main..HEAD
```

Expected: 29 commits, one per task.

---

## Self-review notes

- Spec sections 1-6 all have task coverage.
- Tasks numbered 1-29 in execution order; later tasks depend on earlier ones.
- Each context module (`Accounts`, `Invites`, `OauthCredentials`) ships with full TDD coverage in its first task plus an integration round-trip in Task 28.
- Migration ordering trap (Task 1 referencing `invite_codes`) is called out explicitly in Task 2.
- Existing tests broken by the route restructure (Task 21) are explicitly audited and fixed inline using new `log_in_as_*` helpers added to ConnCase.
- The `~p"/auth/invite"` early-compilation issue is called out in Task 16 with a concrete workaround.
- The "leave secret blank to keep" UI semantics (Task 23) is implemented as `effective_secret/2`.
- Boot integration (Task 26) uses a `Task` child after Repo so credentials load before Endpoint listens.
