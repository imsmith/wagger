# GCP URL Map Provider + `partition_by_method_set` Helper Refactor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `(method, path)` allowlisting for GCP from Cloud Armor to the GCP Load Balancer URL Map, where the platform actually scales for it. Cloud Armor stays on the per-backend layer for IP/geo/rate/preconfigured-WAF — its native role. Wagger emits two artifacts per app for GCP: a URL Map fragment and a (now smaller) Cloud Armor policy. Along the way, extract the explode-then-cluster `partition_by_method_set/1` helper from its three current inline copies (gcp, cloudflare, azure) into `Wagger.Generator.PathHelper` so any future fix lands in one place.

**Why:** Cloud Armor's per-policy 200-rule and 1024-char-inner-regex limits cap practical working sets at ~5k `(method, path)` pairs even with optimal bucketing. URL Map's `routeRules` natively support `(method, path)` matching with limits an order of magnitude looser. The trie-compression workaround on Cloud Armor is a one-order-of-magnitude bandaid for the wrong tool; URL Map is where the work belongs in the GCP architecture.

**Tech Stack:** Elixir, Phoenix, ExYang, Comn.Errors, ExUnit. New YANG model for the URL Map output. No new runtime dependencies.

**Sequencing rationale:** Phase 1 (helper refactor) lands first — it's a pure refactor against a green test suite, and Phase 2 will reuse the helper. Phase 2 (URL Map provider) and Phase 3 (Cloud Armor pruning) ship together since pruning Cloud Armor's per-route allow rules without URL Map in place would create a security gap.

---

## File Structure

**New (Phase 2 — URL Map provider):**
- `yang/wagger-gcp-urlmap.yang` — canonical model for URL Map output.
- `lib/wagger/generator/gcp_urlmap.ex` — provider module.
- `test/wagger/generator/gcp_urlmap_test.exs` — unit + full-pipeline tests.
- `test/support/fixtures/gcp_urlmap/minimal.json` — golden output fixture (optional, follow project convention).

**Modified (Phase 1 — helper refactor):**
- `lib/wagger/generator/path_helper.ex` — add `partition_by_method_set/1`.
- `lib/wagger/generator/gcp.ex` — replace inline copy with `PathHelper.partition_by_method_set/1`.
- `lib/wagger/generator/cloudflare.ex` — same.
- `lib/wagger/generator/azure.ex` — same.
- `lib/wagger/generator/aws.ex` — replace `Enum.group_by(& &1.methods)` (a simpler precursor of the same idea) with the new helper for consistency. Verify behaviour is equivalent first; AWS may rely on input grain in ways the explode-then-cluster discipline normalises.
- `test/wagger/generator/path_helper_test.exs` — add tests for the new function.

**Modified (Phase 3 — Cloud Armor pruning):**
- `lib/wagger/generator/gcp.ex` — drop per-bucket allow rules and the deny-all rule; keep rate-based-ban rules and the mandatory default rule. Update moduledoc.
- `test/wagger/generator/gcp_test.exs` — remove or rewrite tests asserting per-route allow rules; keep rate-limit and default-rule tests.
- `yang/wagger-gcp-armor.yang` — review whether allow-rule containers should be removed or made optional.

---

## Phase 1 — Extract `partition_by_method_set/1`

### Task 1.1: Add the helper to `PathHelper`

**Files:**
- Modify: `lib/wagger/generator/path_helper.ex`

- [ ] **Step 1: Add `partition_by_method_set/1` with full docstring**

Add a new public function. Signature:

```elixir
@doc """
Partitions routes by their effective HTTP-method-set using explode-then-cluster.

The semantic key for an allowlist is `(method, path)`, not `path` alone. To
pack densely while preserving correctness, we:

1. Explode each route into atomic `(method, path)` pairs
2. Dedupe (two source routes can both contribute `(GET, /a)`)
3. Group atoms by path → reconstruct each path's effective method-set
4. Group paths by method-set → one bucket per distinct set

Each path lands in exactly one bucket. The mapper function is invoked per
path with the route record so callers can project paths to their preferred
shape (regex, wildcard, raw path, etc.).

Returns a list of `{sorted_methods, [mapped_path, ...]}` tuples in
deterministic order for stable rule priorities across runs.

## Example

    iex> routes = [
    ...>   %{path: "/a", methods: ["GET", "POST"], path_type: "exact"},
    ...>   %{path: "/b", methods: ["GET"], path_type: "exact"}
    ...> ]
    iex> Wagger.Generator.PathHelper.partition_by_method_set(routes, & &1.path)
    [{["GET"], ["/b"]}, {["GET", "POST"], ["/a"]}]
"""
def partition_by_method_set(routes, mapper) when is_function(mapper, 1) do
  routes
  |> Enum.flat_map(fn r -> Enum.map(r.methods, &{&1, r}) end)
  |> Enum.uniq_by(fn {m, r} -> {m, r.path} end)
  |> Enum.group_by(fn {_, r} -> r.path end)
  |> Enum.map(fn {_path, atoms} ->
    methods = atoms |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.uniq()
    route = atoms |> List.first() |> elem(1)
    {methods, mapper.(route)}
  end)
  |> Enum.group_by(fn {methods, _} -> methods end, fn {_, mapped} -> mapped end)
  |> Enum.sort_by(fn {methods, _} -> methods end)
end
```

The mapper-injected design is what lets the same helper serve gcp (regex), cloudflare (full route record), azure (regex), and the future url-map provider (route record + path-type tag).

### Task 1.2: Test the helper

**Files:**
- Modify: `test/wagger/generator/path_helper_test.exs`

- [ ] **Step 1: Add tests covering the explode-then-cluster invariants**

Required test cases:
- Single route with single method → one bucket, one path
- Single route with multi-method → one bucket with that method-set
- Two routes same path, disjoint methods → one bucket with the union
- Two routes same path, overlapping methods → deduped, no double-counting
- Routes with distinct method-sets → distinct buckets, sorted deterministically
- Mapper function applied per path (project to regex, project to raw path)
- Empty route list → empty result

### Task 1.3: Replace inline copies in gcp/cloudflare/azure

**Files:**
- Modify: `lib/wagger/generator/gcp.ex` (delete inline `partition_by_method_set/1`, call `PathHelper.partition_by_method_set(routes, &PathHelper.to_regex/1)`)
- Modify: `lib/wagger/generator/cloudflare.ex` (same; mapper is `& &1` since it needs the full route)
- Modify: `lib/wagger/generator/azure.ex` (same as gcp; regex mapper)

- [ ] **Step 1: Update gcp.ex**

Delete the inline `partition_by_method_set/1`. Update `build_allow_rules/1` to call `PathHelper.partition_by_method_set(normalized, &PathHelper.to_regex/1)`.

- [ ] **Step 2: Update cloudflare.ex**

Delete inline copy. Cloudflare needs the full route record (different `build_path_expression/1` clauses dispatch on `path_type`), so mapper is `& &1`.

- [ ] **Step 3: Update azure.ex**

Delete inline copy. Same as gcp — regex mapper.

- [ ] **Step 4: Run full test suite**

`mix test` must remain at 491/491.

### Task 1.4: Migrate AWS to use the helper

**Files:**
- Modify: `lib/wagger/generator/aws.ex` `build_method_rules/3`

- [ ] **Step 1: Verify equivalence**

AWS currently does `Enum.group_by(& &1.methods)` — a simpler precursor that trusts the route's declared method-list as the bucketing key. With explode-then-cluster, two AWS routes declaring `[GET] /a` and `[POST] /a` would merge into one `[GET, POST]` bucket; under the current code they stay separate. Confirm via test what AWS's intent is.

- [ ] **Step 2: Migrate or document why not**

If the explode-then-cluster semantics are correct for AWS, switch. If AWS deliberately wants per-route grain (e.g., to preserve different rate limits per declaration), document that in `aws.ex` moduledoc and skip this step. Either outcome is acceptable; the goal is to have the call documented either way.

---

## Phase 2 — Build `Wagger.Generator.GcpUrlMap`

### Task 2.1: Author the YANG model

**Files:**
- New: `yang/wagger-gcp-urlmap.yang`

- [ ] **Step 1: Model the URL Map output shape**

Target output is a JSON fragment consumable by `gcloud compute url-maps import`. Top-level structure:

```yaml
gcp-urlmap-config:
  url-map-name: <prefix>-allowlist
  description: <generated description>
  generated-at: <ISO8601>
  default-service: <placeholder backend ref for unmatched traffic>
  path-matchers:
    - name: allowlist-matcher
      default-service: <deny backend placeholder>
      route-rules: [...]
  host-rules:
    - hosts: ["*"]
      path-matcher: allowlist-matcher
```

Each `route-rule` has a priority, a list of `match-rules` (each carrying a path-template/prefix/regex match plus header matches against `:method`), and a `service` reference (the known-traffic backend placeholder).

Open question to resolve during this task: do we model placeholder backend refs as YANG strings the user templates post-emit (e.g. `__KNOWN_TRAFFIC_BACKEND__` and `__DENY_BACKEND__`), or as configurable values in `config.gcp_urlmap.backends`? Default to config-driven so the LiveView UI can collect them.

### Task 2.2: Provider module

**Files:**
- New: `lib/wagger/generator/gcp_urlmap.ex`

- [ ] **Step 1: Implement `Wagger.Generator` callbacks**

Required callbacks: `yang_module/0`, `map_routes/2`, `serialize/2`.

- `map_routes/2` — uses `PathHelper.partition_by_method_set(normalized, & &1)` to bucket routes, then for each bucket emits one or more `route-rule` entries. Path matching uses `pathTemplateMatch` for paths with `{param}` placeholders, `prefixMatch` for `path_type: "prefix"`, `pathMatch` (exact) for plain exact, and `regexMatch` only for `path_type: "regex"`. Method matching via `headerMatches: [{headerName: ":method", exactMatch: <method>}]` for single-method buckets, or repeated `matchRules` for multi-method buckets (URL Map `matchRules` are OR'd within a route rule; `headerMatches` AND together within a single match rule).
- `serialize/2` — JSON output matching the URL Map import format. Pretty-printed.

- [ ] **Step 2: Method-set semantics**

One `routeRule` per method-set bucket. Within each `routeRule`, one `matchRule` per path. Each `matchRule` has one path predicate and one `headerMatches` entry against `:method`:

- **Single-method bucket** (`[GET]`): `headerMatches: [{"headerName": ":method", "exactMatch": "GET"}]`
- **Multi-method bucket** (`[GET, POST]`): `headerMatches: [{"headerName": ":method", "regexMatch": "GET|POST"}]`

Sample emission for a bucket `[GET, POST]` with paths `[/a, /b]`:

```json
{
  "priority": 1,
  "service": "<known-traffic-backend>",
  "matchRules": [
    {
      "pathTemplateMatch": "/a",
      "headerMatches": [{"headerName": ":method", "regexMatch": "GET|POST"}]
    },
    {
      "pathTemplateMatch": "/b",
      "headerMatches": [{"headerName": ":method", "regexMatch": "GET|POST"}]
    }
  ]
}
```

Predicate cost: 2 per matchRule (1 path + 1 header), regardless of method-set size. Under the 1,000-predicate-per-pathMatcher budget this gives ~500 path entries per pathMatcher with 50% headroom. See "URL Map quotas and packing strategy" in Resolved Design Decisions.

- [ ] **Step 3: Default-deny route rule**

After all bucket route rules, emit a final route rule at the lowest priority that matches `/.*` (or omit `matchRules` entirely if URL Map supports a true catch-all) routing to the deny backend placeholder.

### Task 2.3: Tests

**Files:**
- New: `test/wagger/generator/gcp_urlmap_test.exs`

- [ ] **Step 1: Unit tests for `map_routes/2`**

Mirror the pattern in `gcp_test.exs`. Required cases:
- Single route, single method → one route rule + default-deny
- Multi-method route → match rules cover every (path, method) pair within one route rule
- Distinct method-sets → distinct route rules, deterministic priority order
- Routes sharing a method-set → packed in one route rule
- Atomic explosion equivalence (same property test as gcp/cloudflare/azure)
- Default-deny rule exists at lowest priority and routes to deny backend
- All path types (`exact`, `prefix`, `regex`) emit the right URL Map match field

- [ ] **Step 2: Full-pipeline tests via `Generator.generate/3`**

Same shape as `gcp_test.exs` "generate/3 full pipeline" describe block. Assert: valid JSON, top-level shape matches URL Map import format, YANG model parses and resolves.

### Task 2.4: UI surface

**Files:**
- Modify: `lib/wagger_web/live/app_detail_live.ex` (or wherever provider list is registered)
- Modify: any provider registry / dispatch table

- [ ] **Step 1: Register the new provider**

Add `Wagger.Generator.GcpUrlMap` to the provider list so it appears in the per-app generator selection UI alongside `Wagger.Generator.Gcp`. Both should be selectable independently — many users will want only Cloud Armor, only URL Map, or both.

---

## Phase 3 — Trim Cloud Armor

Cloud Armor's role shifts from `(method, path)` allowlisting to defense-in-depth on the known-traffic backend. The shape of the emitted policy now depends on what positive criteria the user has declared. See "Cloud Armor's role in the default-deny architecture" in Resolved Design Decisions for the full posture matrix.

### Task 3.1: Replace per-route allow/deny rules with posture-driven emission

**Files:**
- Modify: `lib/wagger/generator/gcp.ex`
- Modify: `yang/wagger-gcp-armor.yang` — add optional `allow-ip-ranges` (list of CIDRs) and `allow-regions` (list of region codes) containers under config

- [ ] **Step 1: Remove the per-route allow rules and per-route deny-all rule**

`build_allow_rules/1` and `build_deny_all_rule/0` (the existing path-based ones) go away. `map_routes/2` no longer emits per-route allow/deny — that's the URL Map's job now.

- [ ] **Step 2: Add posture-driven allow rule emission**

New private function `build_posture_allow_rules/1` reads `config.gcp.allow_ip_ranges` and `config.gcp.allow_regions` and dispatches:

- Both nil/empty → emit a single permissive allow rule (`expression: "true"` or `srcIpRanges: ["*"]` versioned-expr) with a description like "Permissive allow — Cloud Armor is defense-in-depth behind URL Map; method+path allowlisting handled there." Default rule remains `deny(403)` per contract but is unreachable.
- IP allowlist only → one allow rule per CIDR (or one rule with `srcIpRanges: [list]`) with `inIpRange()`-equivalent matching. Default rule = `deny(403)`. Genuine default-deny posture.
- Geo allowlist only → allow rule with `origin.region_code in [list]` CEL expression. Default = `deny(403)`.
- Both → AND-combined allow rule(s). Default = `deny(403)`.

- [ ] **Step 3: Order rules by priority**

Priority bands (ranges chosen to leave room for future categories):

- `100..199` — preconfigured WAF rules (OWASP CRS, etc.) when added later
- `1000..1999` — rate-based-ban (existing)
- `2000..2999` — posture allow rules (new)
- `3000` — was the per-route deny-all; now unused, free to repurpose
- `2147483647` — default rule, now `deny(403)` instead of `allow`

- [ ] **Step 4: Update moduledoc**

Reframe Cloud Armor's role: rate limiting, IP/geo posture, preconfigured WAF rules. State plainly that `(method, path)` allowlisting is now `Wagger.Generator.GcpUrlMap`'s job and cross-reference. Document the posture-dispatch table in the moduledoc so it's discoverable from `h Wagger.Generator.Gcp`.

### Task 3.2: Update tests

**Files:**
- Modify: `test/wagger/generator/gcp_test.exs`

- [ ] **Step 1: Remove path-based allow-rule and deny-all tests**

Delete or rewrite the describe blocks asserting per-route allow-rule presence, chunking, method enforcement, and the per-route deny-all. Keep rate-limit and pipeline-shape tests.

- [ ] **Step 2: Add tests for posture-driven allow rules**

New describe block "posture allow rules":

- No declared posture → one permissive allow rule emitted; default rule is `deny(403)`
- IP allowlist only → allow rule(s) reference declared CIDRs; default = `deny(403)`
- Geo allowlist only → allow rule references declared region codes; default = `deny(403)`
- Both declared → combined allow logic; default = `deny(403)`
- Regression: a non-empty route list does NOT produce per-route allow rules (prevents accidental re-introduction of the path-based shape)

- [ ] **Step 3: Update default-rule test**

The default-rule test currently asserts `action == "allow"`. Change to assert `deny(403)` and update the description text to reflect the new contract.

### Task 3.3: Optional — prune YANG model

**Files:**
- Modify: `yang/wagger-gcp-armor.yang`

- [ ] **Step 1: Decide on YANG containers**

Either remove the allow-rule containers entirely, or leave them present-but-optional with a deprecation note. Removing is cleaner; leaving is safer if any downstream tool depends on the schema shape. Default to leave-and-deprecate; revisit at a later major version.

---

## Definition of Done

- All three phases committed.
- `mix test` green.
- `mix compile --warnings-as-errors` clean.
- ISSUES.md GCP-scaling entry marked `[x]` with commit refs and a short fix summary.
- README updated: brief note that GCP output is now two artifacts (`gcp-armor.json` for posture, `gcp-urlmap.json` for `(method, path)` allowlisting), with a one-paragraph deployment sketch (which artifact attaches where).
- Memory project_status.md updated to reflect the new architecture invariant: "GCP `(method, path)` allowlisting belongs to the URL Map provider; Cloud Armor is for IP/geo/rate/preconfigured WAF only."

## Out of Scope

- Trie compression for Cloud Armor allow rules (deprecated by this plan; left in ISSUES.md as a "fallback if anyone needs Cloud-Armor-only" note).
- Generating the deny-backend infra itself (Cloud Run service, serverless NEG, etc.). Wagger emits placeholders; deployer wires them.
- A Terraform/Pulumi module wrapping the URL Map fragment. Out of scope; the existing JSON-only emission pattern stays consistent across providers.

## Resolved Design Decisions

### URL Map quotas and packing strategy

Researched against `cloud.google.com/load-balancing/docs/quotas` and `/docs/url-map-concepts`. Authoritative limits:

| Limit | Value | Notes |
|---|---|---|
| URL maps per project | per-project quota, increasable | not binding |
| `pathMatchers` per URL map | 1,000 (External ALB) / 2,000 (Internal) | not binding for v1 |
| **predicates per `pathMatcher`** | **1,000** | **binding constraint** — `routeRules`, `matchRules`, and per-condition predicates (path match, header match, query match, etc.) all count toward this single budget |
| `pathRules` per `pathMatcher` | 1,000 | sibling of `routeRules`, same budget |
| URL map total size | 1 MB | bites at very large sets due to JSON verbosity |
| `pathTemplateMatch` support | Global External ALB, Regional External ALB, Regional Internal ALB, Cross-region Internal ALB, Cloud Service Mesh | **not supported on Classic ALB**; max 5 operators per template |
| `headerMatches` on `:method` | supported | `{"headerName": ":method", "exactMatch": "GET"}` is the documented idiom |

**Default emission strategy (compact-but-not-aggressive, target ~50% headroom under the 1,000-predicate budget per pathMatcher):**

- **One `pathMatcher`** per URL map by default. No automatic sharding in v1. Document the path to shard if a real user pushes past the limit; don't pre-build the machinery.
- **One `routeRule` per method-set bucket** (from `partition_by_method_set`). Deterministic priority order so reruns produce stable output.
- **Within a `routeRule`, one `matchRule` per path.** Each `matchRule` has:
  - A `pathTemplateMatch` (preferred) or `pathMatch`/`prefixMatch`/`regexMatch` (per `path_type`).
  - One `headerMatches` entry against `:method`. For single-method buckets, `exactMatch: "GET"`. For multi-method buckets, `regexMatch: "GET|POST"` — this keeps method enforcement to **one predicate** per matchRule rather than `N`.
- Predicate cost per allowed `(method-set, path)` entry under this scheme: **2 predicates** (1 path + 1 header). Budget of 1,000 predicates → **~500 path entries per pathMatcher** comfortably (with method-set already collapsed into the regex).
- Final fallback `routeRule` at lowest priority routing to the deny backend placeholder. Catch-all match: `pathTemplateMatch: "/{path=**}"` with no header match.

**ALB compatibility:** Default to the **Global External ALB** as the assumed deployment target so `pathTemplateMatch` is available. Note in the YANG model description that Classic ALB is not supported by this provider; users on Classic ALB must use the legacy Cloud-Armor-only path. Don't try to detect or emit fallback regex automatically.

### `pathTemplateMatch` mapping

| `path_type` | URL Map field | Notes |
|---|---|---|
| `exact` (no `{params}`) | `pathMatch` | exact string equality |
| `exact` (with `{params}`) | `pathTemplateMatch` | `/users/{id}` → `/users/{id=*}`. Watch the 5-operator-per-template cap. |
| `prefix` | `prefixMatch` | trailing-slash normalisation as today |
| `regex` | `regexMatch` | passthrough, but flag in moduledoc that this is an escape hatch and shouldn't be the common case |

### AWS migration (Task 1.4 confirmed)

Migrate AWS to the shared `partition_by_method_set` helper. Update tests and chase down any regressions. The explode-then-cluster discipline produces equivalent buckets when input grain matches; if any AWS test breaks, the test was over-fitted to the old grain-trusting behaviour and the new behaviour is the correct one. Document the rationale in the commit message.

### Cloud Armor's role in the default-deny architecture

The system as a whole is default-deny. Each layer must therefore have its own positive-criteria allow story:

**Layer 1 — URL Map (default-deny gate for `(method, path)`):**
- Allow rules: `routeRules` per method-set bucket → known-traffic backend
- Default: route to deny backend (returns 403)
- This is where the working set lives; this is what the quotas above govern.

**Layer 2 — Cloud Armor on the known-traffic backend (defense-in-depth):**

What "allow" means here depends on what positive criteria the user has declared in their wagger config. The provider must dispatch on declared posture:

- **If user declares an IP allowlist** (`config.gcp.allow_ips`): emit allow rules with `inIpRange()` predicates against those CIDRs at low priorities; default rule (`2147483647`) = `deny(403)`. Genuine default-deny posture.
- **If user declares a geo allowlist** (`config.gcp.allow_regions`): emit allow rules with `origin.region_code in [...]` predicates; default = `deny(403)`. Genuine default-deny posture.
- **If user declares both:** combine — allow if (IP in allowlist) AND (region in allowlist), or layer them as separate rules per project policy preference. Default to AND-combination unless config says otherwise.
- **If user declares neither (the common minimal case):** Cloud Armor cannot express a meaningful `(method, path)`-aware default-deny because it doesn't see the URL Map's routing decision. Fall back to: emit a permissive allow rule (`true` CEL or equivalent) with rate-based-ban + preconfigured WAF rules layered above as deny rules. Default rule = `deny(403)` is then unreachable but preserved for contract compliance. Document that in this configuration Cloud Armor is functionally defense-in-depth (rate, WAF) layered behind the URL Map's default-deny gate, not a default-deny layer in its own right.

**Layer 3 — Deny backend (terminal default-deny):**
- A small Cloud Run service or serverless NEG returning `403 Forbidden`. Wagger does not generate this; deployer provides. Document the contract: "URL Map's `defaultService` and unmatched-route fallback both reference this backend."

Implication for the YANG model: `wagger-gcp-armor.yang` needs new optional containers for `allow-ip-ranges` and `allow-regions` so users can declare positive criteria. If both are absent, the provider emits the permissive-allow + deny-default-unreachable shape and surfaces a one-line note in the description field of the policy explaining the layering.
