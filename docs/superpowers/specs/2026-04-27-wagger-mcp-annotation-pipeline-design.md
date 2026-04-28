# Wagger MCP Annotation Pipeline + UI — Design

**Date:** 2026-04-27
**Status:** Approved for planning
**Scope:** Annotation-driven MCP generation. Ships `yang/wagger-mcp-extensions.yang` (eight extension statements), a `Deriver` that walks an annotated YANG module to produce the capability map consumed by the existing `Wagger.Generator.Mcp.Builder`, a new `generate_from_yang/2` entry point, and a standalone LiveView at `/mcp`.

## Context

The first MCP slice (shipped 2026-04-17) added a canonical `yang/mcp.yang` and a generator that emits `my-app-mcp.yang` from a flat capability map. There was no UI and no way to author capabilities short of constructing the map in Elixir. This spec adds the missing surface: an annotation vocabulary on app YANG plus a `/mcp` page that turns annotated YANG into a generated MCP module.

Wagger today has no per-app YANG — Applications carry routes for WAF projection. This spec keeps that boundary intact: the `/mcp` page is BYO YANG and stateless. Persistent per-app YANG storage is a follow-on spec, not this one.

The architectural intent is YANG-as-source-of-truth: app authors annotate their service YANG once, and every regen is push-button. Annotations capture the API-design judgment that no tool can mechanically derive (which RPCs are LLM-callable, what URIs resources live at, LLM-facing descriptions, safety flags).

## Goals

1. Ship a versioned `wagger-mcp-extensions.yang` declaring the annotation vocabulary.
2. Walk annotated YANG and produce a valid capability map plus a derivation report.
3. Standalone `/mcp` page accepts paste/upload, returns derivation report + generated YANG + download link in one round-trip.
4. Default-on policy: every `rpc`, every keyed `list`, and every top-level `container` is exposed unless `wagger-mcp:exclude` is set. Nested non-list containers require explicit `wagger-mcp:resource-template` to be exposed (prevents resource explosion in deeply structured modules).

## Non-goals

- No visual annotation editor (paste/upload is the v1 input mechanism).
- No persistent storage of source or generated YANG (stateless one-shot).
- No coupling to the Applications domain.
- No multi-file support beyond the single uploaded module plus the canonical `mcp.yang` and `wagger-mcp-extensions.yang` shipped with wagger.
- No semantic checks against the MCP JSON-RPC spec — that's contexter's job.

## Architecture

### New artifacts

- `yang/wagger-mcp-extensions.yang` — extension definitions, revision `2026-04-27`.
- `lib/wagger/generator/mcp/deriver.ex` — pure module: annotated `ExYang.Model.Module{}` → `{:ok, capability_map, report}` or `{:error, [reasons]}`.
- `lib/wagger_web/live/mcp_generator_live.ex` and `lib/wagger_web/live/mcp_generator_live.html.heex` — standalone LiveView.
- `lib/wagger_web/controllers/mcp_download_controller.ex` — short-lived `Phoenix.Token`-signed download endpoint.

### Modified

- `lib/wagger/generator/mcp.ex` — add `generate_from_yang(source, app_name) :: {:ok, yang_text, report} | {:error, ErrorStruct.t()}`. Existing `map_capabilities/2` stays unchanged; Deriver becomes a *producer* of capability maps that feed `Builder.build_module/2`.
- `lib/wagger/errors.ex` — register `wagger.generator/derivation_failed` (`:validation`).
- `lib/wagger_web/router.ex` — add `live "/mcp", McpGeneratorLive, :index` and `get "/mcp/download/:token", McpDownloadController, :show`.

## Annotation vocabulary

`yang/wagger-mcp-extensions.yang` declares eight extension statements:

| Extension | Argument | Applies to | Effect |
|---|---|---|---|
| `tool-name` | name (string) | `rpc` | Override auto-derived snake_case tool name |
| `resource-template` | template (string, must contain `{var}` if source is keyed `list`) | `list`, `container` | Override auto-derived URI template |
| `prompt-name` | name (string) | `rpc` | Reclassify rpc as MCP prompt instead of tool |
| `description-for-llm` | text (string) | any node | LLM-facing description, overrides YANG `description` |
| `mime-type` | type (string) | `list`, `container` | Resource MIME type (defaults to `application/json`) |
| `dangerous` | none | `rpc` | Tool requires user confirmation |
| `read-only` | none | `rpc` | Tool has no side effects (MCP optimization hint) |
| `exclude` | none | any node | Opt this node out of MCP exposure |

Module identity: name `wagger-mcp-extensions`, prefix `wagger-mcp`, namespace `urn:wagger:mcp-extensions`, revision `2026-04-27`.

## Default exposure policy

Default-on (denylist):

- Every `rpc` becomes a tool unless `wagger-mcp:exclude`.
- Every `rpc` with `wagger-mcp:prompt-name` becomes a prompt instead.
- Every keyed `list` (at any depth) becomes a resource unless `wagger-mcp:exclude`.
- Every top-level `container` (direct child of the module) becomes a resource unless `wagger-mcp:exclude`.
- Nested (non-list) `container` nodes are NOT auto-exposed; they require explicit `wagger-mcp:resource-template` to opt in. This prevents resource explosion in deeply structured modules.

Auto-derivation rules when annotations are absent:

- Tool name: kebab→snake-case of the rpc identifier (e.g. `create-note` → `create_note`). Override via `tool-name`.
- Resource URI template for keyed `list`: `<list-name>://{<key-leaf-name>}` (e.g. `list notes { key id; }` → `notes://{id}`). Override via `resource-template`.
- Resource URI template for top-level `container`: `<container-name>://` (no interpolation). Override via `resource-template`.
- Resource URI template for explicitly annotated nested node: taken from the `wagger-mcp:resource-template` argument verbatim.
- Description (in priority order): `description-for-llm` → YANG `description` → identifier (warning emitted).
- MIME type: `mime-type` → `application/json` (warning when defaulted).

## Data flow

1. User loads `/mcp` (LiveView mount with empty assigns).
2. User pastes YANG into a textarea or uploads a `.yang` file via `live_file_input`.
3. User clicks "Generate". LiveView calls `Wagger.Generator.Mcp.generate_from_yang(source, app_name)`.
4. `generate_from_yang/2` chains:
   1. `ExYang.parse(source)` — fail → `wagger.generator/yang_parse_failed`.
   2. `ExYang.resolve(parsed, registry)` against a registry containing `wagger-mcp-extensions.yang` (and `mcp.yang` if needed) — fail → `wagger.generator/yang_resolve_failed`.
   3. `Deriver.derive(parsed, app_name)` — `{:ok, capability_map, report}` or `{:error, [reasons]}` (latter → `wagger.generator/derivation_failed`).
   4. `Builder.build_module(capability_map, %{})` — returns `{:ok, module_struct}` or `wagger.generator/invalid_capabilities`.
   5. `ExYang.Encoder.Encoder.encode(module_struct)` — returns `{:ok, yang_text}`.
   6. Return `{:ok, yang_text, report}`.
5. LiveView renders three sections inline:
   - **Derivation report** — counts (e.g. "3 tools, 2 resources, 0 prompts"), per-primitive table (name, source YANG node path, description source, flags), warnings list, excluded-nodes list.
   - **Generated YANG** — `<pre>` block with emitted source.
   - **Download link** — `GET /mcp/download/:token` where `token` is a `Phoenix.Token`-signed payload of `%{yang_text, filename}` with 5-minute TTL.
6. On error: red-bordered error card with code, message, YANG node path (if any). No download link.

`app_name` source: parsed from the uploaded module's name, stripping a trailing `-mcp` suffix if present, otherwise the module name verbatim. No separate input field.

Stateless: nothing persisted server-side except the signed token's payload (in the token itself, not stored).

## Error handling

Three failure layers, mapped to four error IDs.

**Existing (reused):**
- `wagger.generator/yang_parse_failed` (`:internal`) — source doesn't parse.
- `wagger.generator/yang_resolve_failed` (`:internal`) — source parses but doesn't resolve.
- `wagger.generator/invalid_capabilities` (`:validation`) — derived map fails `Builder.validate/1`.

**New:**
- `wagger.generator/derivation_failed` (`:validation`) — registered in `lib/wagger/errors.ex`. Fires when:
  - Two `rpc`s produce the same auto-derived snake_case name with no `tool-name` override.
  - A `list`/`container` lacks a `key` and has no explicit `resource-template`.
  - `wagger-mcp:tool-name` and `wagger-mcp:prompt-name` both present on the same `rpc`.
  - `wagger-mcp:resource-template` argument lacks `{var}` interpolation when the source is a keyed `list`.

Error message includes the YANG node path (e.g., `/rpcs/create-note`); `field:` is set to the path so UI can highlight.

**Warnings (do NOT block generation):**
- Tool with no `description-for-llm` and no YANG `description` — falls back to identifier.
- Resource without `mime-type` — defaults to `application/json`.
- Tool flagged both `dangerous` and `read-only` — semantic conflict; both flags emitted.

Validation order is fail-fast: parse → resolve → derive → build → encode. First failure stops the chain.

LiveView surface:
- Errors render in a red-bordered card; no download link.
- Warnings render as a yellow-bordered list inside the derivation report.

## Components

| Unit | Path | Role |
|---|---|---|
| Extension module | `yang/wagger-mcp-extensions.yang` | Hand-authored. Eight extension declarations. |
| Deriver | `lib/wagger/generator/mcp/deriver.ex` | Pure: annotated module → capability map + report |
| Provider extension | `lib/wagger/generator/mcp.ex` (modified) | Adds `generate_from_yang/2` chaining parse+resolve+derive+build+encode |
| Error registration | `lib/wagger/errors.ex` (modified) | One new ID: `derivation_failed` |
| LiveView | `lib/wagger_web/live/mcp_generator_live.ex` (+ template) | `/mcp` page, paste/upload, single-submit, render report+yang+download |
| Download controller | `lib/wagger_web/controllers/mcp_download_controller.ex` | Token-signed download endpoint |
| Router | `lib/wagger_web/router.ex` (modified) | Two routes added |

No new deps. No changes to Applications domain. No persistence.

## Testing

**`test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`** — canonical extension module
- Parses, resolves against empty registry.
- All eight extensions present with correct argument clauses (or no argument for the three flag extensions).
- Revision date equals `2026-04-27`.

**`test/wagger/generator/mcp/deriver_test.exs`** — unit tests, fixture-driven
- Auto-derivation: rpc kebab→snake; keyed list URI template; presence container as resource.
- Overrides: `tool-name`, `resource-template`, `prompt-name`, `description-for-llm`, `mime-type`.
- Exclusion: `exclude` removes node from output, adds to `report.excluded`.
- Prompt branch: rpc with `prompt-name` becomes prompt, not tool.
- Description fallback chain with warning emission.
- Error cases: duplicate names, list without key, conflicting tool-name+prompt-name, missing `{var}` in resource-template.
- Report shape: counts, warnings, excluded match output.

**`test/wagger/generator/mcp_test.exs`** — extend with `describe "generate_from_yang/2"`
- Round-trip: small annotated fixture → generated module parses, resolves against canonical `mcp.yang`, contains expected primitive names.
- Golden fixture: full-coverage annotated input → byte-equal output (revision date normalized) at `test/support/fixtures/mcp/annotated_service-mcp.yang`.
- Error path each: parse, resolve, derivation, capability validation.

**`test/wagger_web/live/mcp_generator_live_test.exs`** — LiveView
- Mount `/mcp` renders textarea + file input + submit; no result region.
- Submit valid YANG → result region appears with derivation report rows, generated YANG `<pre>`, download link.
- Submit invalid YANG → error card; no download link.

**`test/wagger_web/controllers/mcp_download_controller_test.exs`**
- Valid token → 200, body equals payload's `yang_text`, correct `Content-Type` and `Content-Disposition`.
- Expired token → 410 Gone.
- Forged/garbage token → 403.

Out of scope: visual annotation editor, per-app YANG storage, multi-file imports beyond the canonical pair, MCP JSON-RPC spec semantic conformance.

## Open questions for implementation

- Exact shape ex_yang uses to surface `ExtensionUse` instances on parsed nodes (likely under `:meta` per the existing struct definitions). Resolve during Deriver implementation by reading `deps/ex_yang/lib/ex_yang/parser/grammar.ex` and the resolver source.
- Whether `ExYang.resolve/2` accepts a registry containing both `mcp.yang` and `wagger-mcp-extensions.yang`, or if `generate_from_yang/2` only needs the extensions module at resolve time (the canonical `mcp.yang` only matters for the round-trip resolve in the existing `generate_capabilities/3` path). Read `deps/ex_yang/lib/ex_yang/resolver/*.ex` and decide.

## Follow-on specs (not this one)

- Visual annotation editor in LiveView (point-and-click toggling, inline description editing).
- Per-app YANG storage on the Applications schema, with versioning via wagger snapshots.
- `mcp2yang` ingest parser (separate project).
- Contexter runtime framework (separate project).
- Concrete typed refinement of tool input/output JSON Schema via `deviation`.
