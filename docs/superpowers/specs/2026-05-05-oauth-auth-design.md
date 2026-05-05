# OAuth + Local-Password Auth — Design

**Date:** 2026-05-05
**Status:** Design approved; ready for implementation plan
**Scope:** Add Ueberauth-based OAuth (Google + GitHub) and local-password authentication, gating wagger's browser/LiveView surface. Includes invite-code-gated registration, admin role, admin UI for invites and OAuth provider credentials, and `Comn.Secrets`-backed storage of OAuth client secrets.

## 1. Goals and Scope

Add Ueberauth-based OAuth login (Google + GitHub) that gates wagger's browser/LiveView surface and serves as the account-creation path. First OAuth login for a given verified email creates a User; subsequent logins (same provider, or any other linked provider for that email) establish a session. New-user creation is gated behind a valid, unexpired invite code; existing users skip the prompt. The first admin is bootstrapped via an env var (no invite code needed for that one email).

Browser/LiveView routes require a logged-in session except `/login`, the OAuth callbacks, and the post-OAuth invite-code prompt. The API path stays on its existing Bearer-API-key auth, unchanged.

The design coexists with the planned magic-link path (deploy-intent memory). Magic-link is **out of scope** for this cut and shaped so it can be added later without rework. **In scope:** OAuth (Google + GitHub), local password as a third login path on the same `/login` page, and `Comn.Secrets`-backed storage of OAuth provider credentials so secrets aren't env-var-only.

## 2. Schema Changes

### `users` table — add columns

- `email` (string, nullable). Canonical email for the user. Set when they OAuth in (or later via local-password). Nullable so existing API-key-only users (the seeded admin) don't break the migration; populated when they first OAuth.
- `role` (string, default `"user"`). Values: `"admin"`, `"user"`. Stored as string (not Ecto.Enum) for flexibility; validated in changeset.
- `invite_code_id` (foreign key to `invite_codes`, nullable). Records which code the user signed up with. Bootstrap admin and pre-existing users have null.
- Existing fields (`username`, `display_name`, `password_hash`, `api_key_hash`) are unchanged. `password_hash` is now used for local-password auth (was reserved before).
- Migration: existing user with `username = "admin"` gets `role = "admin"`; everyone else gets `role = "user"`.
- Unique index on `email` (where not null) so two users can't share an email.

### New `oauth_identities` table

- `id`
- `user_id` (belongs_to User)
- `provider` (string: `"google"` or `"github"` — extensible)
- `provider_uid` (string, the provider's stable subject id — Google `sub`, GitHub `id`)
- `email` (string, email reported by provider at link time)
- `raw_info` (text, EDN-encoded raw provider payload for audit/forensics)
- timestamps (`type: :string` to match existing convention)
- Unique index on `(provider, provider_uid)`
- Index on `user_id`

### New `invite_codes` table

- `id`
- `code` (string, unique). Random URL-safe slug, generated server-side, ~16 chars (`:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)`). Stored cleartext (it's coordinative, not a password).
- `label` (string, nullable). Free-form ("elixirforum-launch", "team-2026q2") so the operator can see what's converting.
- `expires_at` (string timestamp, nullable). Null = no expiry.
- `max_uses` (integer, nullable). Null = unlimited uses.
- `uses_count` (integer, default 0). Incremented on successful redemption.
- `revoked_at` (string timestamp, nullable). Soft-revoke without deleting (preserves history of who used it).
- `created_by_user_id` (belongs_to User, nullable)
- timestamps
- Index on `code`

Querying "who used this code" is a join `users.invite_code_id = invite_codes.id` — no separate uses table needed.

### New `oauth_provider_credentials` table

- `id`
- `provider` (string, unique — `"google"` | `"github"`)
- `client_id` (string, cleartext)
- `client_secret_locked` (text — base64-encoded locked blob from `Wagger.Secrets.lock/1`)
- timestamps

## 3. Auth Flow

### Components

- **Deps:** `ueberauth`, `ueberauth_google`, `ueberauth_github`, `argon2_elixir`.
- **`WaggerWeb.AuthController`** with two actions: `request/2` (delegates to Ueberauth) and `callback/2` (the brain of the flow). Routes `/auth/:provider` and `/auth/:provider/callback`. Plus `invite_form/2` and `invite_submit/2`.
- **`WaggerWeb.SessionController`** for `get /login`, `post /login` (password submission), and `delete /logout`.
- **Login page (`/login`)** — two OAuth buttons ("Sign in with Google", "Sign in with GitHub") plus an email + password form. OAuth buttons hit `/auth/google` and `/auth/github`; the form submits to `SessionController.create`.
- **Invite-code page (`/auth/invite`)** — only reachable mid-flow when OAuth succeeded but no User exists for the verified email; collects invite code and finalizes registration.
- **Account settings page (`/account`)** — authenticated LiveView for managing linked identities and password.

### OAuth callback logic

After Ueberauth has populated `conn.assigns.ueberauth_auth`:

1. **Failure branch:** if assigns has `:ueberauth_failure`, flash a generic "couldn't sign in with that provider" message, redirect to `/login`. Do not leak provider error details.
2. **Extract** `provider`, `provider_uid` (`auth.uid`), `email`, `email_verified?`, `display_name`, `raw_info` (the whole `auth` struct, minus credentials/tokens — we don't store access tokens).
3. **Reject unverified email.** Google ships a `verified` flag in `auth.extra.raw_info["email_verified"]`; GitHub: request scope `user:email`, then only consider an email if its `primary && verified` flag is true. If no verified email comes back, flash "your provider must give us a verified email address" and redirect to `/login`. No partial accounts.
4. **Look up by `(provider, provider_uid)`** in `oauth_identities`:
   - **Found** → log in that user. Done.
5. **Else, look up User by `email`** (exact match):
   - **Found** (user previously linked another provider, or set a local password before linking any OAuth) → create a new `oauth_identities` row linking to that user, log in.
6. **Else** the email is new to the system. Decide:
   - **If `email == Application.get_env(:wagger, :bootstrap_admin_email)`:** create User with `role: "admin"`, no invite code, create the oauth_identity, log in.
   - **Else:** stash `{provider, provider_uid, email, display_name, raw_info}` in the session under `:pending_oauth`, redirect to `/auth/invite`.

### Invite-code redemption (`/auth/invite`)

- GET requires a `:pending_oauth` in session; without it, redirect `/login`.
- Single-field form. POST validates the code:
  - Exists, not soft-revoked, not expired, `uses_count < max_uses` (or `max_uses` is null).
  - On valid: insert User with `role: "user"`, `email`, `display_name`, `invite_code_id`; insert oauth_identity from the stashed pending payload; increment `uses_count`; clear `:pending_oauth`; log in; redirect to dashboard. All inside a `Repo.transaction`.
  - On invalid: flash specific reason ("expired", "no uses left", "not recognized", "revoked"), keep the user on the page.

### Local-password login

`SessionController.create/2` calls `Wagger.Accounts.authenticate_by_password(email, password)`; on success, log in and redirect; on failure, generic "email or password incorrect" flash (do not distinguish missing-user from wrong-password).

`Wagger.Accounts` gains:

- `set_password(user, plaintext)` — argon2-hashes (via `argon2_elixir`) and updates `password_hash`. Validates length (≥ 12 chars) in changeset.
- `authenticate_by_password(email, plaintext)` — looks up user by email; if not found, runs `Argon2.no_user_verify/0` to maintain constant-time behavior; otherwise verifies hash with `Argon2.verify_pass/2`. Returns `{:ok, user}` or `{:error, :invalid_credentials}`.
- `clear_password(user)` — for "remove password" account-settings action; sets `password_hash` to nil. Refused if it would leave the user with no auth method.

Local-password is **not** a signup path. New users still come in via OAuth + invite code; they may add a password afterwards via account settings. This avoids a second registration surface and keeps the invite-code gate definitive.

### Account settings

Authenticated LiveView at `/account`. Shows: email, linked OAuth identities (with "unlink" button for each), "Set/change password" form, "Remove password" button. The "no orphan accounts" rule lives in `Wagger.Accounts` and is enforced symmetrically — last-method removal is rejected with a clear error, regardless of whether it's a password or an identity being removed.

### Logout

`delete /logout` clears the session, redirects to `/login` with a flash. No CSRF concerns beyond Phoenix's existing `:protect_from_forgery`.

### Edge cases

- Provider returns no verified email → reject (above).
- User has email `a@x.com` on Google; logs in with GitHub which reports `b@y.com` — these are different identities to different accounts by design. Linking happens only on email match.
- Bootstrap env var stays set after first use → idempotent: matching email always logs in the admin user; doesn't re-create or duplicate.
- Pending invite-code session is short-lived (cleared on success, on `/login` revisit, or by Phoenix session expiry).

## 4. Session Model and Route Gating

### Session storage

Phoenix's default cookie session store, signed with the existing endpoint secret. Session contains only `user_id` (integer) and, transiently during OAuth, `pending_oauth` (map). No tokens stored in session. Cookie attributes: `secure: true` in production (`runtime.exs`), `http_only: true`, `same_site: "Lax"` (default — needed because OAuth callbacks come from a redirect, not a cross-site POST).

### Plugs

Two new plugs in `lib/wagger_web/plugs/`:

- **`FetchCurrentUser`** — runs in the `:browser` pipeline after `:fetch_session`. Reads `user_id` from session, loads the User (`Repo.get(User, id)`), assigns `:current_user` (or `nil`). Never halts.
- **`RequireUser`** — runs in the new `:authenticated` pipeline. If `conn.assigns.current_user` is nil, store the requested path in session as `:return_to`, redirect to `/login`, halt. After successful login, the callback redirects to `:return_to` if present, else `/`.
- **`RequireAdmin`** — runs in the `:admin` pipeline (after `:authenticated`). If `current_user.role != "admin"`, render 403 (no automatic redirect — admin routes shouldn't bounce non-admins to login when they're already logged in).

### LiveView mounting

A new on_mount hook `WaggerWeb.Hooks.AuthHook` with two clauses:

- `:require_user` — reads `user_id` from session, loads User; if absent, halts the mount with a redirect to `/login`. Assigns `:current_user`.
- `:require_admin` — same as above plus role check; halts with a 403-flash + redirect to `/` for non-admins.

Each existing `live_session` adds the appropriate hook alongside the existing `NavHook`. The `live_session :default` and `:hub` blocks both get `:require_user`. A new `live_session :admin` is added for admin LiveViews with `:require_admin`.

### Router shape

- `:browser` pipeline gains `FetchCurrentUser` after `:fetch_session`.
- New `:authenticated` pipeline = `[RequireUser]`.
- New `:admin` pipeline = `[RequireAdmin]` (used after `:authenticated`).
- Public scope `/`: only `/login`, `/logout`, `/auth/:provider`, `/auth/:provider/callback`, `/auth/invite`.
- Authenticated scope `/`: all existing LiveViews (`/`, `/applications`, `/applications/:id`, `/users`, `/mcp`, `/hub`, `/hub/:name`) plus `/account`, plus `/mcp/download/:token`.
- Admin scope `/admin`: `/admin/invites`, `/admin/oauth`.
- API scope `/api` is unchanged; keeps Bearer API key.

### Comn.Contexts

The existing `Comn.Contexts.new/1` call lives only in the API auth plug today. For browser-driven actions, populate `Comn.Contexts` in a small helper called from authenticated LiveViews' mount, with `actor: current_user.username`. Mirrors the API plug's existing pattern.

## 5. Admin UI

### `Wagger.Invites` context

`lib/wagger/invites.ex`:

- `create_code(attrs, created_by)` — generates a fresh URL-safe code, inserts the row, returns `{:ok, code}` or `{:error, changeset}`. Caller can supply `label`, `expires_at`, `max_uses`.
- `list_codes()` — returns all codes, newest first, with preloaded `created_by` user. Computes a virtual `:status` field on each (`:active` / `:expired` / `:revoked` / `:exhausted`) for display.
- `redeem(code, oauth_payload)` — atomic: validates + creates User + creates oauth_identity + bumps `uses_count` inside a single `Repo.transaction`. Returns `{:ok, user}` or `{:error, reason}` where reason is one of `:not_found`, `:revoked`, `:expired`, `:exhausted`. This is what `AuthController.invite_submit` calls.
- `revoke(code)` — sets `revoked_at: now`. Idempotent.
- `users_for_code(code)` — `Repo.all(from u in User, where: u.invite_code_id == ^code.id)`.

### Admin invite-code LiveView (`/admin/invites`)

Single LiveView, `WaggerWeb.InviteCodeLive`. Three regions:

1. **"Generate new code" form** — fields: optional label, optional expires_at (date picker), optional max_uses (integer or "unlimited"). Submit → `Wagger.Invites.create_code/2`. The newly-generated code is shown once in a flash banner with a copy-to-clipboard button.
2. **Codes table** — columns: `code`, `label`, `created_by`, `created_at`, `expires_at`, `uses` (`uses_count` / `max_uses`), `status`, actions. Status is computed per-row. Actions: "Revoke" (for active codes), "Show users" (expands an inline list).
3. **Empty state** — when there are zero codes, show a one-paragraph "what is this" explainer with the bootstrap-admin reminder.

Codes are displayed cleartext (they're coordinative).

### Admin OAuth credentials LiveView (`/admin/oauth`)

`WaggerWeb.OauthCredentialsLive`. Lists configured providers (`google`, `github`) with fields `client_id` (cleartext, editable) and `client_secret` (write-only — shown as `••••` once set, with a "Replace" action that reveals an input). Saving locks the secret with `Wagger.Secrets.lock/1`, persists the encrypted blob, and updates `Application.put_env(:ueberauth, …)` so Ueberauth picks up the new value on the next request without restart.

### `Wagger.OauthCredentials` context module

`lib/wagger/oauth_credentials.ex`:

- `get(provider)` — returns `{:ok, %{client_id: …, client_secret: plaintext}}` or `:error`. Decrypts the secret on read.
- `upsert(provider, client_id, client_secret)` — locks the secret, upserts the row by provider, calls `load_into_app_env/0` after success.
- `load_into_app_env/0` — for each row, decrypts and calls `Application.put_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, …)` (or the GitHub equivalent). Called on application boot and after each upsert. Falls back to env vars (one-time) for any provider with no DB row but env vars present, seeding the row.
- `provider_configured?(provider)` — true when DB row + decrypted secret are present; powers the "disable button on /login" UI.

### Boot sequence

1. `Wagger.OauthCredentials.load_into_app_env/0` runs after Repo starts and before Endpoint.
2. For each provider with a row → decrypt and `Application.put_env/3`.
3. For each provider *without* a row, fall back to env vars (`GOOGLE_OAUTH_CLIENT_ID`/`SECRET`, `GITHUB_OAUTH_CLIENT_ID`/`SECRET`) — if env vars are set, seed the DB row from them and lock the secret. This is the only time env vars touch OAuth: one-time bootstrap; afterwards DB is authoritative.
4. If neither DB row nor env vars are present for a provider, that provider's button on `/login` is disabled with a "not configured" tooltip; no boot failure.

### Navigation

The top nav (`NavHook` / layout) gains an "Admin" link visible only when `current_user.role == "admin"`. Submenu: "Invite codes", "OAuth credentials". Authenticated non-admin users see no Admin link.

### Out of admin scope (parking lot)

Editing existing invite codes, deleting users, promoting/demoting other users to admin, viewing audit logs of OAuth events.

## 6. Configuration, Secrets, and Testing

### Configuration

`WAGGER_BOOTSTRAP_ADMIN_EMAIL` env var is read in `config/runtime.exs` (it's a property of the deploy, not a secret). OAuth provider credentials are **not** read from `config/runtime.exs` after first bootstrap — they live in the DB encrypted via `Wagger.Secrets`, and `Wagger.OauthCredentials.load_into_app_env/0` populates `Application.put_env(:ueberauth, …)` at boot.

Initial-bootstrap env vars (`GOOGLE_OAUTH_CLIENT_ID`/`SECRET`, `GITHUB_OAUTH_CLIENT_ID`/`SECRET`) are read **only** by the boot loader, only when the corresponding DB row is absent, and only to seed it. After seeding, the env vars can be removed from the deploy.

In dev, the boot loader's "no creds, no DB row" branch logs a clear message and disables the affected provider's button on `/login`; no crash. Admin can paste real creds into the admin UI to enable the provider, no restart needed.

`Comn.Secrets.Local` is the encryption substrate — same key (`priv/secrets/wagger.key`) used for snapshot lock/unlock today. Future migration to a host-side credentials broker (per the credentials-broker memory) is out of scope but not foreclosed.

### Dependencies

- `ueberauth`
- `ueberauth_google`
- `ueberauth_github`
- `argon2_elixir`

### Testing strategy

**Unit-level — contexts:**

- `Wagger.Accounts`: User creation paths, oauth_identity creation, email-based linking, role assignment, password set/change/clear, `authenticate_by_password` including timing-safe negative path, "no orphan account" enforcement.
- `Wagger.Invites`: code generation, redemption (atomic), revocation, expiry, exhaustion, bootstrap-admin idempotency.
- `Wagger.OauthCredentials`: upsert + lock round-trip, `load_into_app_env` writes the right `Application.put_env` keys, env-var fallback seeds the DB on first boot then becomes a no-op.

**Controller / LiveView-level:**

- `AuthController.callback`: all six branches (failure, unverified email, existing identity, email match, bootstrap admin, new email → redirect to invite). Tests stub `conn.assigns.ueberauth_auth` directly (Ueberauth's documented test approach).
- `AuthController.invite_submit`: valid/expired/exhausted/revoked/not-found/missing-pending.
- `SessionController.create`: password success, password failure, constant-time on missing user.
- LiveView gating: unauthenticated → redirect, authenticated non-admin → 403 on admin routes, admin → render. Account settings: cannot remove last auth method.
- Admin OAuth credentials LiveView: secret is masked on read, replace flow re-locks the new value, app env updates after save.

**Encryption round-trip integration test:** insert a credential row, call `load_into_app_env` directly, assert `Application.get_env(:ueberauth, …)` matches the original plaintext. Catches `Wagger.Secrets`/`Comn.Secrets` misintegration at the data boundary.

**End-to-end against real Google/GitHub** is a manual smoke test in the deploy runbook.

### Out of scope (parking lot)

- Magic-link auth (separate scope; deploy-intent memory).
- Email allowlist by domain (invite-code model chosen).
- User merging (when the same person ends up with two accounts via different emails).
- Audit log of OAuth events.
- Self-service "link my GitHub to my Google account" — account settings shows linked identities and lets you unlink, but doesn't drive a fresh OAuth from there. Linking happens by signing into the provider; the existing email-match logic in the callback handles the merge.
- Migration to host-side credentials broker.
- Password reset (no email substrate yet; the magic-link follow-on covers this).
- Editing existing invite codes, deleting users, promoting/demoting other users to admin.
