# Wagger

Your application has a finite set of valid endpoints. Your WAF should know about them. Wagger bridges the gap: define your routes once, generate WAF configs for whatever platform you're deploying to.

From one route table you can select nine outputs: eight WAF configs -- AWS WAF, Cloudflare, Azure Front Door, GCP (Cloud Armor plus URL Map, emitted together), Nginx, Caddy, Apache (mod_security2), Coraza/ModSecurity -- and an OWASP ZAP test plan that verifies your deployed config is actually blocking what it should. A tenth generator, MCP, takes annotated YANG instead of a route table and lives on its own page; see below.

Import routes from OpenAPI specs, bulk text, or access logs. Share API definitions through the public Hub. Get notified when your routes drift from the last generated config.

## GCP

Wagger emits two artifacts for GCP: `gcp-armor.json` (Cloud Armor security policy — rate limiting, IP/geo posture, defense-in-depth) and `gcp-urlmap.json` (URL Map fragment — the default-deny gate for `(method, path)` allowlisting via `pathTemplateMatch` + `:method` headerMatches).

Deployment sketch: URL Map attaches to the Global External HTTPS Load Balancer; Cloud Armor attaches to the known-traffic `backendServices` referenced by the URL Map's matched routeRules. The deployer provides a deny backend (a small Cloud Run service or serverless NEG returning 403) referenced by the URL Map's `defaultService` and `pathMatchers[].defaultService` and the URL Map's final default-deny route-rule's `service`. Wagger emits placeholders `__KNOWN_TRAFFIC_BACKEND__` and `__DENY_BACKEND__` (overridable via config) which the deployer substitutes for real `projects/PROJECT_ID/.../backendServices/...` refs.

Targets Global External Application Load Balancer and other modern ALB variants where `pathTemplateMatch` is supported. Classic ALB is unsupported by `Wagger.Generator.GcpUrlMap` because `pathTemplateMatch` is unavailable there; users on Classic ALB can use `Wagger.Generator.Gcp` (Cloud Armor) alone, but with much tighter scaling limits on the path allowlist.

The `gcp` provider always emits both artifacts in one output, separated by labelled `====` headers naming each file. There is no URL-Map-only or Cloud-Armor-only selection: the two are designed as halves of one deployment, and splitting the output at the header is trivial for anyone who needs just one.

## MCP

`/mcp` generates a Model Context Protocol module from YANG you paste in. Annotate your service's YANG with `wagger-mcp:*` extensions (see `yang/wagger-mcp-extensions.yang`), submit, and wagger returns a derivation report, the generated `<app>-mcp.yang` importing the canonical `yang/mcp.yang`, and a download link. The generator (`Wagger.Generator.Mcp`) implements the same `Wagger.Generator` behaviour as the WAF providers via the `map_capabilities/2` callback, but because its input is annotated YANG rather than a stored application's routes it is not in the per-application provider list. Wiring it per-application is blocked on deciding where those annotations live; see the Parking Lot in `ISSUES.md`.

For the full story -- why the architecture looks the way it does, how the generators work under the hood, and what the YANG validation layer is about -- read the [literate program](docs/waf-rule-generator-literate.md).

## Running it

With Elixir installed:

```sh
git clone https://github.com/imsmith/wagger.git
cd wagger
mix setup
mix phx.server
```

Without Elixir:

```sh
docker build -t wagger .
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=$(openssl rand -base64 48) \
  -e PHX_HOST=localhost \
  -v wagger_data:/data \
  wagger
```

Either way, open [localhost:4000](http://localhost:4000).

## Authentication

The browser/LiveView surface is gated behind login. Users sign in via
Google OAuth, GitHub OAuth, or local password.

A fresh database has no users and no sign-up page, so the first admin is
seeded from the environment. Set `WAGGER_BOOTSTRAP_ADMIN_EMAIL` and
`WAGGER_BOOTSTRAP_ADMIN_PASSWORD` (12 characters minimum) before first boot;
the admin is created with that local password while the users table is empty
and the seed is a no-op forever after. If only the email is set, the OAuth
login matching it is promoted to admin and bypasses the invite-code gate
instead.

> **Important:** unset both variables on the deploy after the first admin signs in. Leaving the email set means any OAuth identity matching it becomes admin on a fresh sign-in.

OAuth provider credentials live encrypted in the database (via
`Wagger.Secrets`). For first-time bootstrap, set the env vars
`GOOGLE_OAUTH_CLIENT_ID`/`SECRET` and/or `GITHUB_OAUTH_CLIENT_ID`/`SECRET`;
they will be read on boot, stored encrypted, and the env vars can then be
removed from the deploy. Subsequent rotation happens via the admin UI at
`/admin/oauth`.

Invite codes (admin UI at `/admin/invites`) gate new-user registration.
The API path remains on its existing Bearer-API-key authentication.

## Dependencies

Wagger pulls two libraries that are also ours:

- [comn](https://github.com/imsmith/comn) -- shared infrastructure (structured errors, request contexts, event bus, encryption at rest)
- [ex_yang](https://github.com/imsmith/ex_yang) -- YANG model parser used to validate generator output before serialization

Both resolve automatically via `mix deps.get`.

## License

AGPL-3.0
