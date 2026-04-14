# Wagger Design Spec

*A provider-agnostic web application for defining application URL allowlists and generating Web Application Firewall configurations.*

---

## Overview

Wagger is a self-hosted Phoenix application with a JSON API. Teams and home lab operators define their application routes in a canonical format, then generate WAF configurations for multiple cloud and edge providers. The system tracks generation history and detects drift between route definitions and last-generated configs.

The literate program at `waf-rule-generator-literate.md` is the conceptual foundation. This spec describes the production implementation.

## Architecture

Monolith Phoenix application. Single deployment unit — one container on Alpine with SQLite embedded. No external database dependency.

**Stack:**

- Elixir/Phoenix with LiveView
- SQLite via `ecto_sqlite3`
- EDN for data storage and export artifacts
- JSON on the API wire (`application/vnd.wagger+json`)
- YANG models (parsed by `ex_yang`) as formal schemas for provider config formats
- AGPL-3.0 license

**Key dependencies:**

- `phoenix` + `phoenix_live_view`
- `ecto` + `ecto_sqlite3`
- `ex_yang` — YANG schema parsing and resolution (path dependency)
- `wauthn` — WebAuthn/FIDO2 ceremony handling
- `jason` — JSON encoding for API responses and generated configs

No YAML parser. OpenAPI import accepts JSON specs only.

## Data Model

### Applications

Top-level grouping. Each application represents one web service.

| Field | Type | Notes |
|-------|------|-------|
| id | integer | PK |
| name | text | unique, slug-style (`my-api`) |
| description | text | |
| tags | text | EDN list |
| inserted_at | text | ISO 8601 |
| updated_at | text | ISO 8601 |

### Routes

Belong to an application. Mirror the canonical schema from the literate doc.

| Field | Type | Notes |
|-------|------|-------|
| id | integer | PK |
| application_id | integer | FK |
| path | text | OpenAPI-style with `{param}` placeholders |
| methods | text | EDN list `[:GET :POST]` |
| path_type | text | `exact`, `prefix`, `regex` |
| description | text | |
| query_params | text | EDN `[{:name "page" :required false}]` |
| headers | text | EDN `[{:name "Authorization" :required true}]` |
| rate_limit | integer | requests per minute, nullable |
| tags | text | EDN list |
| inserted_at | text | |
| updated_at | text | |
| | | UNIQUE(application_id, path) |

Structured fields stored as EDN text in SQLite, parsed on read via Ecto custom types.

### Generation Snapshots

Foundation for drift detection. Records what was generated, when, for which provider.

| Field | Type | Notes |
|-------|------|-------|
| id | integer | PK |
| application_id | integer | FK |
| provider | text | `aws`, `cloudflare`, `azure`, `gcp`, `nginx`, `caddy` |
| config_params | text | EDN — provider-specific config |
| route_snapshot | text | EDN — frozen copy of routes at generation time |
| output | text | generated config verbatim |
| checksum | text | SHA-256 of route_snapshot for fast drift comparison |
| inserted_at | text | |

### Users

| Field | Type | Notes |
|-------|------|-------|
| id | integer | PK |
| username | text | unique |
| display_name | text | |
| password_hash | text | nullable — for basic auth |
| api_key_hash | text | nullable — SHA-256 of API key |
| inserted_at | text | |
| updated_at | text | |

### Credentials

Separate table for WebAuthn and HTTP Message Signature credentials. A user can have multiple (e.g. multiple FIDO2 keys, multiple signing keys).

| Field | Type | Notes |
|-------|------|-------|
| id | integer | PK |
| user_id | integer | FK |
| type | text | `webauthn`, `http_sig` |
| label | text | user-assigned name ("YubiKey 5", "CI signing key") |
| credential_data | blob | WebAuthn credential or public key |
| inserted_at | text | |

## API Design

RESTful JSON API. All endpoints under `/api`. Versioning via Accept header content negotiation:

```
Accept: application/vnd.wagger+json; version=1
```

Default to version 1 if absent or plain `application/json`.

### Applications

```
GET    /api/applications                     — list (filterable by tag)
POST   /api/applications                     — create
GET    /api/applications/:id                  — show
PUT    /api/applications/:id                  — update
DELETE /api/applications/:id                  — delete
```

### Routes

```
GET    /api/applications/:app_id/routes               — list (filterable by tag, method, path_type)
POST   /api/applications/:app_id/routes               — create
GET    /api/applications/:app_id/routes/:id            — show
PUT    /api/applications/:app_id/routes/:id            — update
DELETE /api/applications/:app_id/routes/:id            — delete
```

### Import

Two-step: preview then confirm. All three importers return a preview response with parsed routes, conflicts against existing routes, and skipped/unparseable lines.

```
POST   /api/applications/:app_id/import/bulk           — text format
POST   /api/applications/:app_id/import/openapi        — OpenAPI JSON spec
POST   /api/applications/:app_id/import/accesslog      — access log file
POST   /api/applications/:app_id/import/confirm        — commit previewed routes
```

Preview response shape:

```json
{
  "preview_token": "a1b2c3",
  "parsed": [{"path": "/api/users", "methods": ["GET", "POST"]}],
  "conflicts": [{"path": "/api/users", "existing": {}, "incoming": {}}],
  "skipped": ["unparseable line 14: ..."]
}
```

The confirm endpoint accepts the full preview payload (client holds state, not server). The `preview_token` is a HMAC of the parsed routes — the server verifies the confirm payload hasn't been tampered with between preview and confirm. No server-side session state.

### Generation

```
POST   /api/applications/:app_id/generate/:provider    — generate config
GET    /api/applications/:app_id/snapshots              — list generation history
GET    /api/applications/:app_id/snapshots/:id          — show specific snapshot
```

Generate accepts provider-specific config in request body, returns generated config text, stores a snapshot.

### Drift Detection

```
GET    /api/applications/:app_id/drift/:provider       — compare current routes vs last snapshot
```

Response:

```json
{
  "provider": "aws",
  "status": "drifted",
  "last_generated": "2026-04-10T14:30:00Z",
  "changes": {
    "added": [{"path": "/api/widgets", "methods": ["GET"]}],
    "removed": [{"path": "/api/legacy", "methods": ["GET", "POST"]}],
    "modified": [{"path": "/api/users", "field": "rate_limit", "was": 100, "now": 200}]
  },
  "stale_rules": 1,
  "missing_rules": 1
}
```

### Export

```
GET    /api/applications/:app_id/export                — EDN route file
```

Content-Type: `application/edn`.

## Generators

Six provider modules implementing a common behaviour. Each generator produces configs validated against a YANG model.

### YANG-Driven Architecture

Each provider's WAF config format is formally modeled as a YANG module:

```
yang/
  wagger-common.yang          — shared types (path-pattern, http-method, rate-limit)
  wagger-aws-waf.yang         — AWS WAF v2 Web ACL structure
  wagger-cloudflare.yang      — Cloudflare firewall rules
  wagger-azure-fd.yang        — Azure Front Door WAF policy
  wagger-gcp-armor.yang       — GCP Cloud Armor security policy
  wagger-nginx.yang           — nginx WAF config model
  wagger-caddy.yang           — Caddy route/matcher config model
```

### Generation Pipeline

1. `ex_yang` parses and resolves the provider's YANG model at app startup (cached in Registry)
2. Mapper module takes `[Route.t()]` + provider config, builds an Elixir map conforming to the YANG model tree
3. Instance validator (built in Wagger on top of `ex_yang`) checks the populated tree against the YANG schema — types, constraints, mandatory leaves, list keys
4. Serializer converts the validated tree to the provider's native format

### Behaviour

```elixir
defmodule Wagger.Generator do
  @callback yang_module() :: String.t()
  @callback map_routes(routes :: [Route.t()], config :: map()) :: map()
  @callback serialize(instance :: map(), schema :: ExYang.ResolvedModule.t()) :: String.t()
end
```

`generate/2` is a shared function that orchestrates: load schema, call `map_routes`, validate instance, call `serialize`.

### Instance Validator

Built in Wagger on top of what `ex_yang` provides. `ex_yang` parses and resolves YANG schemas but does not validate data instances against them. The validator walks a populated map against a resolved YANG module tree and checks:

- Mandatory leaf presence
- Type constraints (string, integer, enumeration, union)
- List key uniqueness
- Range and length restrictions
- Pattern constraints on string values
- When/must expression evaluation (subset)

### Providers

- **AWS WAF** (`Wagger.Generator.Aws`) — AWS WAF v2 JSON. `OrStatement` of `ByteMatchStatements` with URL_DECODE + LOWERCASE transforms. Rate limits multiplied by 5 for 5-minute window.
- **Cloudflare** (`Wagger.Generator.Cloudflare`) — Firewall rules JSON. Expression language: `eq` for exact, `starts_with` for prefix, `matches` for regex/wildcard. `managed_challenge` for rate limits.
- **Azure Front Door** (`Wagger.Generator.Azure`) — WAF policy JSON. `RegEx` match conditions with `negateCondition`. Rate limits multiplied by 5.
- **GCP Cloud Armor** (`Wagger.Generator.Gcp`) — Security policy JSON. CEL expressions for path matching.
- **Nginx** (`Wagger.Generator.Nginx`) — nginx.conf text. `map` directive for path validation, `location` blocks with `limit_except`, `limit_req` zones.
- **Caddy** (`Wagger.Generator.Caddy`) — Caddyfile text. `route` blocks with `@matcher` directives, `respond 403` for unmatched, `rate_limit` directive.

### Path Translation

Shared `Wagger.Generator.PathHelper` module handles canonical-to-provider path conversion. Curly brace params to wildcards/regex per provider.

Bug fix from literate doc: paths with interior wildcards (`/api/v1/users/*/profile`) use `RegexMatchStatement` in AWS and proper regex in all providers, not `CONTAINS` or substring matching.

## Import Pipelines

Three import paths, all producing the same intermediate format.

### Bulk Text

The format from the literate doc: `METHOD /path - description`, one per line. Express-style `:param` normalized to `{param}`. Comment lines (`#`) filtered. Non-matching lines skipped silently.

### OpenAPI

Accepts JSON OpenAPI 3.x specs. Extracts paths, methods, parameter definitions, descriptions. Path parameters already in `{param}` format. Maps parameter locations to query_params and headers.

### Access Log

Configurable format detection:

- Nginx combined/common log format
- Apache combined/common
- Caddy default JSON log format
- AWS ALB log format

Extracts unique URI paths stripped of query strings, groups by observed HTTP methods, ranks by request count. Inherently noisy — the review step before confirmation is critical.

## Drift Detection

Compares current route state against last generation snapshot per provider.

### Algorithm

1. **Fast check** — hash current routes (sorted, serialized to EDN, SHA-256), compare against snapshot checksum. If equal, no drift.
2. **Structural diff** — if hashes differ, diff the two route sets: added, removed, modified routes.
3. **Impact assessment** — for each change, note affected provider rules. New route = missing allowlist entry. Removed route = stale rule. Method change = wrong enforcement rule.

Computed on demand when queried. No background polling.

## Authentication

Three tiers, matching the audience from home lab to enterprise.

### Tier 1: API Keys (default)

First run creates the initial user with a generated API key. `Authorization: Bearer <key>`. Keys stored as SHA-256 hashes — plaintext shown once at creation. No admin role — any authenticated user has full access.

### Tier 2: WebAuthn/FIDO2 (browser)

Passwordless browser auth via LiveView. Server generates challenges, browser talks to FIDO2 authenticator. Session via signed cookie. Users can have both WebAuthn credential and API key.

### Tier 3: HTTP Message Signatures (RFC 9421)

Request signing for API consumers. Server stores client public key. Requests include `Signature` and `Signature-Input` headers. Replay-resistant, non-repudiable.

### Auth Pipeline

`Wagger.Auth` behaviour with three implementations. A pipeline plug tries HTTP Signature first, then Bearer token, then session cookie. First match wins.

No roles or permissions in v1. Any authenticated user can do anything. Authorization designed when a real multi-team use case exists.

## LiveView UI

Designed around Magic Ink principles: information-first, manipulation-secondary.

### Dashboard (Home)

System health overview — all apps, all providers, all drift status visible without interaction. Status encoded through color and position: green (current), amber (drifted, with change count), red (never generated). The entire state of the system is visible on one screen with zero clicks.

### App Detail

Route surface visualization organized by path hierarchy (not a flat table). Drift diffs shown inline per provider. Import area always visible at the bottom — a single text area that auto-parses as you paste, shows preview inline with conflicts highlighted in-place. Confirm is the only interaction.

### Config View

Generated output with diff against previous generation. Provider config fields pre-filled from last generation parameters (last-value defaults). If drift is detected, the regenerated config is already computed and shown as a diff. User decision is "accept this" or "not yet."

### User Management

Simple CRUD. Create users, issue API keys, register WebAuthn credentials, upload public keys for HTTP Message Signatures.

### UI Principles

1. Dashboard-first, not list-first
2. Manipulation is secondary — route editing, import, user management are reachable but not prominent
3. Pre-compute everything — drift status, regenerated previews, import parse results computed eagerly
4. Inline over modal — no modals, no wizards, everything in-context
5. Last-value defaults everywhere — provider config, export format, filter state remembered

## Project Structure

```
wagger/
  lib/
    wagger/
      applications/
        application.ex
        route.ex
      import/
        bulk.ex
        openapi.ex
        access_log.ex
        preview.ex
      generator/
        generator.ex            — behaviour definition
        path_helper.ex
        validator.ex            — YANG instance validation
        aws.ex
        cloudflare.ex
        azure.ex
        gcp.ex
        nginx.ex
        caddy.ex
      snapshots/
        snapshot.ex
        drift.ex
      auth/
        auth.ex
        api_key.ex
        webauthn.ex
        http_sig.ex
      accounts/
        user.ex
    wagger_web/
      plugs/
        api_version.ex
        authenticate.ex
      controllers/
        application_controller.ex
        route_controller.ex
        import_controller.ex
        generate_controller.ex
        snapshot_controller.ex
        drift_controller.ex
        export_controller.ex
        user_controller.ex
      live/
        dashboard_live.ex
        app_detail_live.ex
        config_live.ex
        user_live.ex
      components/
        drift_badge.ex
        route_tree.ex
        diff_view.ex
        import_area.ex
      router.ex
  yang/
    wagger-common.yang
    wagger-aws-waf.yang
    wagger-cloudflare.yang
    wagger-azure-fd.yang
    wagger-gcp-armor.yang
    wagger-nginx.yang
    wagger-caddy.yang
  priv/
    repo/
      migrations/
    static/
  test/
    wagger/
      generator/
      import/
      snapshots/
      validator/
    wagger_web/
      controllers/
      live/
  mix.exs
  config/
    config.exs
    dev.exs
    prod.exs
    runtime.exs
```
