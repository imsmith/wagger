# OAuth Provider Setup

How to register Google and GitHub OAuth apps and feed their client IDs and secrets into wagger. Both providers are free.

Once credentials are saved at `/admin/oauth`, the corresponding "Sign in with …" button on `/login` activates. The bootstrap-admin shortcut (`WAGGER_BOOTSTRAP_ADMIN_EMAIL`) only fires if that env var is set when the server boots; it's optional once a local-password admin exists.

## Callback URLs wagger expects

| Provider | Production | Local dev |
| --- | --- | --- |
| Google | `https://<host>/auth/google/callback` | `http://localhost:4000/auth/google/callback` |
| GitHub | `https://<host>/auth/github/callback` | `http://localhost:4000/auth/github/callback` |

The URL registered at the provider must match byte-for-byte (scheme, host, path, no trailing slash). Mismatch shows up as `redirect_uri_mismatch` after the consent screen.

Google allows multiple authorized redirect URIs on one OAuth app; GitHub allows only one. For GitHub, register two separate apps if you want dev and prod, or edit the URL when switching.

## Google

1. Go to <https://console.cloud.google.com/apis/credentials>. Pick (or create) a project.
2. If prompted, configure the **OAuth consent screen** first.
   - User type: **External**.
   - Fill in app name + support email.
   - Scopes: add `email` and `profile`.
   - Leave the app in **Testing** mode and add your own email under **Test users**. Verification is only required to let users outside the test list log in.
3. **Credentials → Create Credentials → OAuth client ID**.
4. Application type: **Web application**.
5. Authorized redirect URIs: add the callback URL(s) from the table above.
6. **Create**. Google shows a modal with:
   - **Client ID** — long string ending in `.apps.googleusercontent.com`.
   - **Client secret** — shorter random string starting with `GOCSPX-`.
7. Paste both into `/admin/oauth` in wagger.

Reference: <https://developers.google.com/identity/protocols/oauth2/web-server>

## GitHub

1. Go to <https://github.com/settings/developers> → **OAuth Apps** → **New OAuth App**.
   (For an org-owned app: `https://github.com/organizations/<org>/settings/applications`.)
2. **Application name**: anything (shown on the consent screen). e.g., `wagger`.
3. **Homepage URL**: your site, or `http://localhost:4000` for dev.
4. **Authorization callback URL**: the GitHub callback URL from the table above. GitHub limits one per app.
5. **Register application**.
6. On the resulting page:
   - Copy the **Client ID** (shown on the page).
   - Click **Generate a new client secret** and copy the **Client secret** immediately. GitHub shows the secret once.
7. Paste both into `/admin/oauth` in wagger.

Reference: <https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app>

## Where wagger stores the secrets

Client secrets are encrypted at rest via `Wagger.Secrets` (Ed25519 key at `priv/secrets/wagger.key`) and persisted in the `oauth_provider_credentials` table. They never appear in plaintext on disk after the upsert. The `/admin/oauth` page shows them as `••••` once set; type a new value into the secret field to rotate.

Initial bootstrap can also use env vars (`GOOGLE_OAUTH_CLIENT_ID`/`GOOGLE_OAUTH_CLIENT_SECRET`, `GITHUB_OAUTH_CLIENT_ID`/`GITHUB_OAUTH_CLIENT_SECRET`). On boot, if those env vars are set and no DB row exists for that provider, wagger seeds the DB row from the env var and locks the secret. After that, the env vars can be removed from the deploy and the DB is authoritative.

## Rotating a secret

1. Generate a new secret at the provider (Google: regenerate on the credential page; GitHub: "Generate a new client secret" — old secret remains valid until you revoke it).
2. Paste the new secret into `/admin/oauth`. Wagger re-locks and persists it; subsequent OAuth requests use the new value immediately (no restart needed).
3. Revoke the old secret at the provider once you've confirmed the new one works.
