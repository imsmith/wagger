# Bloom Provider — Design

**Date:** 2026-05-04
**Status:** Design approved; ready for implementation plan
**Scope:** New wagger generator that emits per-Application Bloom-filter artifacts for edge-deployable positive-security pre-filtering.

## 1. Goal and Posture

A new wagger provider, `bloom`, emits a per-Application artifact set encoding the Application's exact-match routes as a Bloom filter. Consumers (eBPF first, then wasm, then Plug) probe the filter with a canonicalized `(method, path)` pair; a miss is a definitive deny. Prefix routes ship as a sidecar lookup table; regex routes are explicitly out of scope and fall through to the next layer.

The posture is strict positive security: a bloom miss means deny, full stop. Staleness is an operational concern surfaced via a self-describing header, not papered over with TTLs or fail-open behavior. The producer (wagger) carries the snapshot id of the ruleset it was built from; the consumer logs it at load time; operators detect drift with monitoring.

This design enables eBPF, wasm, and Plug consumers but only commits to shipping the **Plug as the canonical reference consumer** in this project. eBPF and wasm consumers are specified-but-deferred to follow-on projects.

## 2. Artifact Set per Application

One export run for an Application produces three files in a versioned directory, e.g. `bloom/<app-slug>/<snapshot-id>/`:

- `routes.bloom` — the Bloom filter: fixed-size header plus bit array. Loadable directly into a Linux `BPF_MAP_TYPE_BLOOM_FILTER` (jhash, kernel 5.16+), or read by wasm/Plug consumers as a flat bit vector. Encodes only `path_type: exact` routes, expanded per method (one entry per `(method, path)` pair).
- `routes.prefix` — sidecar lookup table for `path_type: prefix` routes. Sorted records of `(method_id, prefix_len, prefix_bytes)`; consumer does longest-match. Same header convention as `routes.bloom`.
- `manifest.edn` — operator-readable companion: app id, snapshot id, generation timestamp, FPR target, m, k, n entries, excluded route count and reason (regex, malformed, non-ASCII path, etc.), expected canonicalization rules, hash function (jhash / lookup3), seed. Not consulted at runtime — this is the human/CI-facing description of what was built.

`routes.bloom` and `routes.prefix` are self-describing via their headers; `manifest.edn` is the operator's single source of truth for an export.

## 3. Canonicalization Spec (Wire Contract)

This is the precise rule producer and all consumers must implement identically. Anything more lenient on one side and the bloom lies.

### Method canonicalization

1. Take the HTTP method bytes as received.
2. ASCII-uppercase them.
3. Reject (treat as bloom miss → deny) anything not in the standard set: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`. Non-standard methods are out of scope.

### Path canonicalization

1. Take the request-target bytes (origin-form).
2. Truncate at the first `?` or `#` (strip query and fragment).
3. If the resulting path has length > 1 and ends in `/`, drop the trailing `/`. (`/api/v1/users/` → `/api/v1/users`. The single-byte `/` is preserved as-is.)
4. No percent-decoding. No multi-slash collapse. No `..`/`.` resolution. No case folding on the path. Bytes are otherwise verbatim.

### Hash input

The byte string `METHOD ++ 0x20 ++ PATH` (canonical method, single space separator, canonical path). No trailing null. No length prefix in the hashed bytes themselves.

### Producer-side rejections (recorded in manifest)

- Paths containing `?`, `#`, NUL bytes, or non-ASCII bytes.
- Methods outside the standard set.
- Routes whose `path_type` is `regex` (recorded with reason `"regex"`).

Declared APIs must canonicalize their own routes before declaration; the producer does not silently coerce.

## 4. Bloom File Layout and jhash Usage

### `routes.bloom` byte layout

Little-endian throughout.

```text
offset  size   field
------  ----   -----
0       4      magic         "WBLM"  (Wagger BLooM)
4       2      format_ver    u16, currently 1
6       2      hash_id       u16, 1 = jhash (lookup3, kernel-compatible)
8       8      snapshot_id   u64  (wagger snapshot id)
16      8      generated_at  u64  (unix seconds)
24      4      app_id        u32
28      4      n_entries     u32  (count of inserted method+path pairs)
32      4      m_bits        u32  (filter size in bits, multiple of 64)
36      2      k             u16  (number of hash probes)
38      2      flags         u16  (reserved, must be 0)
40      8      jhash_seed    u64  (low 32 bits = base seed)
48      ...    bit_array     m_bits / 8 bytes, u64-word packed
```

Header is 48 bytes. Total file size = `48 + ceil(m_bits / 8)`.

### Sizing math

For target FPR `p` and entry count `n`:

- `m = -n · ln(p) / (ln 2)²`, rounded up to the next multiple of 64.
- `k = round((m / n) · ln 2)`.

Default FPR 1% → ≈ 9.6 bits per entry, k = 7. Operator may override per export.

### jhash usage (compatible with `BPF_MAP_TYPE_BLOOM_FILTER`)

The kernel's bloom map runs `jhash` `k` times with seeds `seed, seed+1, ..., seed+k-1` and reduces each to a bit index modulo `m_bits`. Wagger does the same on the producer side. `jhash_seed` in the header is the base seed (kernel default 0; wagger writes 0 unless the operator overrides).

### Insertion (producer)

For each `(method, path)` exact route:

1. Build hash input `METHOD ++ 0x20 ++ PATH` (canonical).
2. For `i = 0..k-1`, compute `h_i = jhash(input, base_seed + i)`.
3. Set `bit_array[h_i mod m_bits] = 1`.

### Probe (consumer)

Identical procedure. If all `k` bits are set, "probably allowed → fall through to next layer." If any bit is zero, "definitely not declared → deny."

### `routes.prefix` layout

Same 48-byte header (magic `"WPRF"`; `hash_id`, `seed`, `m_bits`, `k` are unused and zero), followed by `n_entries` records. Each record:

```text
1 byte  method_id   1=GET, 2=POST, 3=PUT, 4=PATCH, 5=DELETE, 6=HEAD, 7=OPTIONS
2 bytes prefix_len  u16
N bytes prefix_bytes (canonical-path bytes; no trailing slash unless the prefix is "/")
```

Sorted by `(method_id, prefix_bytes)` ascending so consumers can binary-search to the method's range and longest-match-scan within it.

## 5. Wagger Integration

### New module

`Wagger.Generator.Bloom` at `lib/wagger/generator/bloom.ex`. Slots in alongside `cloudflare.ex`, `gcp.ex`, `coraza.ex`, etc., and follows the same provider contract those modules use. Implementation will mirror the existing pattern; exact return shape will be confirmed during plan-writing against `lib/wagger/generator/generator.ex` and `multi.ex`.

### Per-route triage at export time

- `path_type: "exact"` → expand into `(method, path)` pairs across the route's `methods` list, canonicalize, insert into bloom.
- `path_type: "prefix"` → expand similarly, canonicalize prefix, append to prefix table records.
- `path_type: "regex"` → record in the manifest's `excluded` list with reason `"regex"`. Not encoded.
- Any route that fails canonicalization (non-ASCII path, contains `?`, etc.) → recorded in `excluded` with reason; producer does not silently accept.

### jhash port

Small `Wagger.Generator.Bloom.Jhash` module — pure-Elixir port of Bob Jenkins' lookup3 (jhash). Public-domain reference; ~50 lines of bit twiddling. Property tests verify it byte-for-byte against published jhash test vectors (Linux kernel tree has them) so the on-disk artifact is provably kernel-compatible.

### FPR knob

Operator-configurable per export. Plumbed through whatever existing option channel the other generators use (multi-export controller / Hub UI / mix task — match the existing convention rather than inventing one). Default 1%. Stored in `manifest.edn` so the artifact carries its own provenance.

### Hub UI

Register the new provider in the same place `gcp_urlmap`, `coraza`, `zap`, etc. were registered. UI shows: provider name, FPR setting, last export's snapshot id and entry count, excluded route count with drill-down.

### Snapshot integration

Use the existing snapshot id as the artifact's pinned ruleset version (`snapshot_id` in the header). This is how staleness becomes legible to operators — the bloom always carries the snapshot it was built from, and wagger's existing snapshot machinery is the authoritative "what's current."

## 6. Reference Consumer and Testing

### Canonical reference: Elixir Plug

Shipped inside wagger at `lib/wagger/bloom/plug.ex` (or a small companion lib — exact factoring decided in the plan). Loads a `routes.bloom` + `routes.prefix` pair on startup, exposes `call/2` that performs canonicalization + bloom probe + prefix longest-match, and either passes the conn through (probably allowed → next plug) or returns 403 (definite deny). Logs the header's snapshot id and generation time at boot so operators see what they loaded.

The Plug is the **executable spec**: every other consumer (eBPF, wasm) is correct iff its outputs match the Plug's on the same artifact and request set. Cheap to test, cheap to reason about, lives in the language wagger is already written in.

### eBPF and wasm

Specified, deferred. This design *enables* both — jhash + `BPF_MAP_TYPE_BLOOM_FILTER` choice was made specifically so the bloom artifact loads natively into the kernel, and the byte layout is wasm-friendly — but neither consumer ships in the first cut. Each gets its own follow-on project with its own brainstorm. The bloom provider is complete without them.

### Testing strategy in this project

1. **jhash parity tests** — port jhash kernel test vectors into a property test; if these pass, kernel and Plug agree on every hash.
2. **Canonicalization tests** — table-driven (method case, trailing slash, query strip, rejected inputs).
3. **Round-trip tests** — for a generated artifact, every declared exact route probes positive; a curated set of undeclared paths probes negative; observed FPR across a large random sample is within target.
4. **Plug integration tests** — full request/response through the plug, both denied and allowed paths, prefix-route paths, header-staleness logging at boot.
5. **Manifest coverage** — every excluded route appears in the manifest with the right reason.

### Out of scope (parking lot)

- Multi-tenant / host-keyed filters (current scope is per-app, one app per artifact).
- Hot reload of artifacts inside a running consumer.
- Partial / delta updates to a deployed bloom (ship a fresh artifact instead).
- eBPF and wasm reference consumers (separate projects).
- TTL or fail-open behavior on staleness (deliberately rejected; positive-security posture).
