# ISSUES

Newest first.

## A fresh deployment has no way to create its first user

**Filed:** 2026-08-11
**Reported from:** first Fly.io deploy
**Resolved:** 2026-10-12 — option 2. `Wagger.Accounts.bootstrap_admin/0` runs from the supervision tree after migrations and seeds an admin with a local password from `WAGGER_BOOTSTRAP_ADMIN_EMAIL` + `WAGGER_BOOTSTRAP_ADMIN_PASSWORD` while `setup_required?/0` is true. Transactional, so a short password leaves no half-made user. README updated. Note: the API-side `allow_setup` escape hatch in `Plugs.Authenticate` is still wired to nothing in the router (left in place, flagged).

### Symptom

Deploying to a new environment produces a database with zero users. Every
browser route then redirects to `/login`, and no path in the application can
create an account:

- There are no default credentials. `priv/repo/seeds.exs` inserts nothing, and
  the release does not run seeds in any case.
- There is no sign-up route. `lib/wagger_web/router.ex:30-39` exposes only
  `/login`, `/logout`, `/auth/invite`, and `/auth/:provider`.
- `/auth/invite` (`lib/wagger_web/controllers/auth_controller.ex:107`) requires
  both a `:pending_oauth` session and a valid invite code. Invite codes are
  minted by an admin, and no admin exists.

The only way in is `Wagger.Accounts.create_user/1` plus
`Wagger.Accounts.set_password/2` from a remote console — which is how the
2026-08-11 Fly deploy was bootstrapped.

### Why it happens

The setup-mode escape hatch was only ever wired to the API. `Plugs.Authenticate`
(`lib/wagger_web/plugs/authenticate.ex:69`) checks
`Accounts.setup_required?/0` and, when the users table is empty, assigns
`setup_mode: true` and lets the request through unauthenticated.

The browser pipeline has no equivalent. `Plugs.RequireUser`
(`lib/wagger_web/plugs/require_user.ex`) redirects to `/login` whenever
`:current_user` is nil, with no reference to `setup_required?/0`. Auth was built
against a development database that already contained the `admin` row, so the
empty-database case never surfaced locally.

### What should change

Give the browser a first-run path gated on `Accounts.setup_required?/0`, so the
gate closes permanently the moment the first user exists. Two candidates, not
yet decided:

1. A `/setup` route that renders a create-admin form when
   `setup_required?/0` is true and 404s or redirects to `/login` otherwise.
2. A boot-time seed in the supervision tree that creates the admin from
   `ADMIN_EMAIL` / `ADMIN_PASSWORD` when the users table is empty. No UI, but it
   puts a plaintext password in the environment.

Either way the check must be `setup_required?/0` — a count of zero users — and
not a config flag someone can forget to turn off. Note that `set_password/2`
enforces a 12-character minimum, and `create_user/1` infers its attribute-key
type from the first key in the map, so any bootstrap code must pass uniformly
string-keyed or atom-keyed attributes.

## MCP download route is public and its "one-shot" token is replayable

**Filed:** 2026-08-04
**Reported from:** as-built architecture review
**Resolved:** 2026-10-12 — route moved into the `[:browser, :authenticated]` scope; moduledoc now states the token is a stateless five-minute bearer, not single-use. Test added for the anonymous redirect.

### Symptom

`lib/wagger_web/router.ex:40` places the download route in the public scope:

```elixir
# --- Public surface ---
scope "/", WaggerWeb do
  pipe_through :browser

  get "/login", SessionController, :new
  ...
  get "/mcp/download/:token", McpDownloadController, :show
end
```

The `:authenticated` pipeline (`router.ex:15-17`, `WaggerWeb.Plugs.RequireUser`)
is not applied. The only thing standing between an anonymous request and the
YANG payload is `Phoenix.Token.verify/4` at
`lib/wagger_web/controllers/mcp_download_controller.ex:13`, with
`@salt "mcp-download"` and `@max_age 300`.

The moduledoc on that controller says "one-shot download". It is not one-shot.
`Phoenix.Token.verify/4` is stateless; nothing records that a token has been
redeemed, and `grep -rn '"mcp-download"' lib` returns exactly two sites — the
`Phoenix.Token.sign` at `lib/wagger_web/live/mcp_generator_live.ex:29` and the
`verify` above. The same URL can be replayed any number of times for the full
five minutes.

The token also carries the payload itself — `%{yang_text: ..., filename: ...}`
is signed into the token, not looked up from a store keyed by the requesting
user — so the URL is a bearer capability for the document, not a reference the
server can revoke or scope.

### Why it happens

The download is a capability URL by design: `/mcp` is behind auth
(`router.ex:56`, inside the `:authenticated` scope), the LiveView signs a token
for the user, and the browser follows the link. Putting the route behind
`RequireUser` would work — the link is followed by an already-logged-in
browser — but the route was placed in the public scope instead, so the token is
doing all the work.

### What should change

Two things need deciding, separately:

1. Whether the route belongs behind `:authenticated`. It appears to cost
   nothing: the only issuer is an authenticated LiveView. Moving it removes the
   anonymous surface entirely.
2. Whether "one-shot" should be made true or the moduledoc corrected. Single-use
   requires server-side state (an ETS table or a DB row keyed by token digest).
   If that is not wanted, drop the phrase — a five-minute replayable bearer URL
   is a defensible design, but the code should say so.

---

## Wagger.Generator.Mcp is in no provider map and in no documentation

**Filed:** 2026-08-04
**Reported from:** as-built architecture review
**Resolved:** 2026-10-12 — the behaviour attribute stays. `Wagger.Generator.generate/3` dispatches on `map_capabilities/2` and the MCP tests exercise exactly that path, so the interchangeability is real at the orchestrator level; what MCP lacks is an `%Application{}` input, which is why it is absent from the per-app provider list. README gained an MCP section saying so. Per-app wiring remains in the Parking Lot.

### Symptom

Eleven modules declare `@behaviour Wagger.Generator`:

```text
lib/wagger/generator/apache.ex:13       lib/wagger/generator/gcp.ex:43
lib/wagger/generator/aws.ex:15          lib/wagger/generator/gcp_urlmap.ex:63
lib/wagger/generator/azure.ex:38        lib/wagger/generator/mcp.ex:13
lib/wagger/generator/caddy.ex:11        lib/wagger/generator/nginx.ex:11
lib/wagger/generator/cloudflare.ex:31   lib/wagger/generator/zap.ex:11
lib/wagger/generator/coraza.ex:15
```

`Wagger.Generator.Mcp` appears in none of the three provider maps
(`generate_controller.ex:24-38`, `app_detail_live.ex:207-220`,
`hub_detail_live.ex:44-57`), so no `POST /api/applications/:id/generate/mcp`
route resolves and it appears in no provider dropdown. It is reached only by
`lib/wagger_web/live/mcp_generator_live.ex:24`, which calls
`Wagger.Generator.Mcp.generate_from_yang(source, app_name)` directly, bypassing
provider dispatch entirely.

`grep -ni mcp README.md` returns nothing. The generator is undocumented.

### Why it happens

MCP took a different input shape — annotated YANG text pasted into a form,
rather than an `%Application{}` with routes — so it got its own LiveView and its
own call path instead of a provider-map entry. The Parking Lot entry at the
bottom of this file records the blocker for wiring it per-app.

### What should change

Decide whether `Wagger.Generator.Mcp` should carry `@behaviour Wagger.Generator`
at all. If it cannot be dispatched like the others because its input is not an
application, the behaviour attribute is asserting an interchangeability that
does not hold, and the honest move is to drop it and document MCP as a separate
tool. If it should be dispatchable, the annotation-source question in the
Parking Lot has to be settled first. Either way, `/mcp` needs a mention in the
README — a shipping feature currently documented nowhere.

---

## README undercounts the generators and omits two of them

**Filed:** 2026-08-04
**Reported from:** as-built architecture review
**Resolved:** 2026-10-12 — README line restated as nine selectable outputs plus MCP; GCP two-artifact note kept.

### Symptom

`README.md:5`:

> Nine generators ship today -- AWS WAF, Cloudflare, Azure Front Door, GCP Cloud
> Armor, Nginx, Caddy, Apache (mod_security2), Coraza/ModSecurity, and an OWASP
> ZAP test plan generator [...]

Eleven modules carry `@behaviour Wagger.Generator` (list above). The nine-key
provider map covers ten of them, because `"gcp"` bundles `Gcp` and `GcpUrlMap`
through `Wagger.Generator.Multi` — README:11-15 does explain the two GCP
artifacts, so the count is defensible there. `Wagger.Generator.Mcp` is the
eleventh and is absent from both the count and the prose.

### What should change

Restate the line in terms of what a user can select rather than a module count,
and add MCP. The GCP two-artifact explanation at README:11 is already correct
and should stay.

---

## Two generators are not independently selectable

**Filed:** 2026-08-04
**Reported from:** as-built architecture review
**Resolved:** 2026-10-12 — decided the pair is indivisible. README now says `gcp` always emits both artifacts and that the `====` separator headers make splitting trivial. No new provider keys. Revisit if a Classic ALB user actually asks.

### Symptom

`Wagger.Generator.GcpUrlMap` appears in the provider maps only inside the `"gcp"`
list value:

```elixir
"gcp" => [
  {"Cloud Armor", Wagger.Generator.Gcp, "gcp-armor.json"},
  {"URL Map", Wagger.Generator.GcpUrlMap, "gcp-urlmap.json"}
],
```

There is no `"gcp_urlmap"` key in `generate_controller.ex`,
`app_detail_live.ex`, or `hub_detail_live.ex`, so a caller who wants only the
URL Map fragment cannot ask for it. `Wagger.Generator.Mcp` has the inverse
problem — reachable only through `McpGeneratorLive`, never through provider
dispatch.

### Why it happens

For GCP this is deliberate: `gcp.ex:8` and README:11-13 describe URL Map and
Cloud Armor as two halves of one deployment, and emitting them together is the
correct default. The gap is that "together" is the only option.

### What should change

Confirm whether URL-Map-only is a real use case. README:15 says Classic ALB
users should use Cloud Armor alone — which is also not independently selectable,
since `"gcp"` always emits both. If either half alone is legitimate, the map
needs keys for them; if not, the README should say the pair is indivisible.

---

## The provider map is triplicated with nothing keeping the copies in sync

**Filed:** 2026-08-04
**Reported from:** as-built architecture review
**Resolved:** 2026-10-12 — hoisted into `Wagger.Generator` (`providers/0`, `provider_names/0`, `fetch_provider/1`, `buckets/0`, `config_fields/1`). GenerateController, AppDetailLive, HubDetailLive and DashboardLive read from it. `test/wagger/generator/registry_test.exs` asserts buckets cover every provider exactly once.

### Symptom

The same nine-key map is defined three times:

- `lib/wagger_web/controllers/generate_controller.ex:24` — `@providers`
- `lib/wagger_web/live/app_detail_live.ex:207` — `@provider_modules`
- `lib/wagger_web/live/hub_detail_live.ex:44` — `@provider_modules`

The keys and values are identical today, including the nested `"gcp"` list. The
adjacent `@provider_config_fields` maps in the two LiveViews are likewise
duplicated. All three are module attributes resolved at compile time; no test,
no macro, and no shared module ties them together.

### Why it happens

Each surface grew its own copy rather than a common one being extracted.

### What should change

Hoist one canonical map into a module the three call — `Wagger.Generator` itself
is the obvious home, alongside the behaviour definition. Field metadata
(`@provider_config_fields`) belongs with it, or on the generator modules as a
callback.

---

-[x] On the /application page, the "Copy" button in each generated config text area does not function as intended. When clicked, it should copy the content of the respective text area to the clipboard, but currently, it does not perform this action. This issue needs to be addressed to enhance user experience and functionality on the application page.
  - Fix: assets/js/app.js — added secure-context check, execCommand fallback for non-HTTPS, and visible "Copied!"/"Copy failed" feedback on the button.

-[x] Also, within the text areas on the /application page a "select all" keyboard shortcut (Ctrl + A or Command + A) does not work as expected. When users attempt to use this shortcut to select all the text within the text area, it fails to select the content, which can be frustrating for users who want to quickly copy or edit the generated configuration. This issue should be resolved to improve usability and ensure that standard keyboard shortcuts function correctly within the application.
  - Fix: the generated-config block is a `<pre>`, not a `<textarea>`. Added `tabindex="0"` + `wagger-copyable` class on the pre (app_detail_live, hub_detail_live) and a global keydown handler that scopes Ctrl/Cmd+A to the focused pre via `Range.selectNodeContents`. Click the block once to focus it, then Ctrl+A selects only that block. 

-[x] **AWS WAF — `SearchString` not base64-encoded.** The AWS WAF JSON output emits `SearchString` as raw text, but the AWS API expects it as a Blob (base64-encoded). Found 2026-04-28 while smoke-testing `avx-waf-test`; worked around by passing `--cli-binary-format raw-in-base64-out` to the AWS CLI. Fix: base64-encode `SearchString` values in the AWS provider's JSON emitter.
  - Fix: `lib/wagger/generator/aws.ex`. Wrapped both `SearchString` emit sites (method enforcement, path allowlist) in `Base.encode64/1`. The `wagger-aws-waf.yang` model is unchanged — it doesn't expose `SearchString` directly; the field is constructed during AWS-API JSON serialization. `RegexMatchStatement.RegexString` is a plain string per the API and is left as-is. Test added that round-trips every `SearchString` through `Base.decode64!/1` and asserts the decoded values match the declared methods and paths. Full suite (471) passes; the AWS CLI workaround `--cli-binary-format raw-in-base64-out` should no longer be needed.

-[x] **ZAP — `responseCode: "!403"` rejected by requestor job.** wagger's generated `zap-config.yml` emits `responseCode: "!403"` to express "not 403", but ZAP's requestor job requires an integer for `responseCode` and rejects the `!`-prefixed negation. Found 2026-04-28 in `avx-waf-test`; currently blocks ZAP integration end-to-end. Fix: express negated response-code assertions via a different mechanism (passive rule? custom comparator? separate field?).
  - Fix: `lib/wagger/generator/zap.ex`. Per ZAP docs, `responseCode` is `Int` and equality-only. Negative jobs now emit unquoted `responseCode: 403` (was `"403"` string). Positive job omits per-request `responseCode` and adds a job-level `tests:` block with `type: stats`, `statistic: "stats.code.403"`, `operator: "=="`, `value: 0`, `onFail: "error"` to fail the job if any request returned 403. Positive job is rendered before negative jobs so its stats test fires before they intentionally produce 403s. Tests updated; full suite (470) passes; output round-trips through a YAML parser.

- [x] **GCP Cloud Armor — allow rules ignore HTTP method.** `lib/wagger/generator/gcp.ex` `build_allow_rules/1` chunks paths into `request.path.matches('<alternation>')` CEL expressions but never references `request.method`. `normalize/1` (line 253) extracts `methods` from the route and then drops it on the floor. Net effect: a route declared `GET /api/users/:id` allows `DELETE /api/users/123` through Cloud Armor. The semantic key for the allow list is `(method, path)`, not `path` alone.
  - Fix: `build_allow_rules/1` now partitions routes by effective method-set (explode→cluster-by-path→cluster-by-method-set), chunks paths within each bucket, and emits one rule per chunk shaped as `request.method in ['GET','POST'] && request.path.matches('<chunk>')`. Single-method buckets use `==` instead of `in [...]`. Each path lands in exactly one bucket and one rule. Costs 2 of 5 sub-expressions per rule (well within budget). Commit `ca20680`.

- [x] **Azure Front Door — allow rule ignores HTTP method.** `lib/wagger/generator/azure.ex` `build_allowlist_rule/2` constructs a single `MatchRule` with one `matchCondition` against `RequestUri` only; method is never referenced. `normalize/1` (line 111) extracts `methods` and drops it. Same shape as the GCP bug.
  - Fix: layered enforcement (option A from the design discussion). Existing path-allowlist rule at priority 1 left unchanged. Added per-method-set Block rules at priority 2..N, each with two AND-ed match conditions: `RequestUri RegEx [bucket-paths]` and `RequestMethod Equal [bucket-methods] negateCondition: true`. Rule type stays `MatchRule` (Azure has no custom MethodEnforcement type); identified by name prefix `EnforceMethods`. Commit `c3cb1f3`.

- [x] **Cloudflare — allow rule ignores HTTP method.** `lib/wagger/generator/cloudflare.ex` `build_path_expression/1` emits `http.request.uri.path` expressions only; method never appears. `normalize/1` (line 118) extracts `methods` and drops it. Same shape as the GCP and Azure bugs.
  - Fix: `build_allowlist_expression/1` now partitions routes by method-set and emits one OR-clause per bucket inside the existing `not (...)` envelope: `not ((http.request.method in {"GET" "POST"} and (p1 or p2)) or (http.request.method eq "GET" and p3) or ...)`. Single-method buckets use `eq`; multi-method buckets use Cloudflare's set syntax `in {...}`. Rate-limit rules left unchanged (separate semantic question). Commit `2a2e1b7`.

- [x] **GCP Cloud Armor — scaling wall on large `(method, path)` working sets.** Even after the method-correctness fix above, the per-policy 200-rule limit caps the practical working set. With trie compression per method-bucket the realistic ceiling is ~10-20k `(method, path)` pairs; beyond that the architecture has to change. Two paths forward, in order of leverage:

  1. **Trie-compress paths within each method partition.** Replace `chunk_regexes/2`'s flat `|` alternation with prefix/trie compression. For typical REST URL shapes this is a 5-10× density win inside the same 1024-char inner-regex limit. Pure `gcp.ex` change, no architecture shift. (Superseded by path 2.)
  2. **Push `(method, path)` allowlisting into the GCP URL Map; reserve Cloud Armor for IP/geo/rate/preconfigured-WAF.** URL Map `routeRules` natively support method matching via `headerMatches` on `:method` plus `pathTemplateMatch` / `prefixMatch` / `regexMatch`, with limits an order of magnitude looser than Cloud Armor's. Wagger would emit a `gcp-urlmap` artifact alongside (or instead of) the Cloud Armor policy. This is the sustainable answer; (1) is the bridge.

  - Fix: built `Wagger.Generator.GcpUrlMap` (`79fd469`–`d102935`) to handle `(method, path)` allowlisting via the GCP Load Balancer URL Map (where the platform actually scales for it — 1,000 predicates per pathMatcher × ~500 paths per matcher comfortably). Reframed `Wagger.Generator.Gcp` as defense-in-depth (`bceb4ec`): rate limiting, IP/geo posture, default `deny(403)`. URL Map is the default-deny gate; Cloud Armor adds posture and rate enforcement on the known-traffic backend. Trie-compression on the old per-route Cloud Armor allow rules is no longer relevant — left in this entry only as a footnote for anyone constrained to the legacy single-provider deployment.

## Parking Lot

- **MCP tab on /applications/:id.** The MCP feature exists at `/mcp` as a paste-and-render flow, but is not surfaced from the per-app page. Wiring it in requires deciding where the YANG annotations come from for an app — `Wagger.Generator.Mcp.generate_from_yang/2` consumes annotated YANG, and apps don't have YANG content stored today (`source` is a file-path/URL marker). Blocked on annotation UX design: where users add `wagger-mcp:*` extensions, whether annotations live on routes, on `app.source`, or in a dedicated field, and how the per-app generator gets fed. Do not implement until the annotation UX is designed.

- **Provider-level rule lookup** (deferred, pick up when there's a concrete user story). The route-level lookup landed in `27c3837` answers "is this request supposed to be allowed by my app's policy?" via `Wagger.Routes.lookup_for_request/3` and the `/api/applications/:id/lookup` endpoint. A natural follow-on is provider-level lookup — "what would Cloud Armor / URL Map / AWS WAF / etc. *actually* do with this request given the generated config?" — which would let users pre-deployment-verify each provider's emitted policy against a hypothetical request. Implementation requires a `lookup/3` per provider that walks the emitted rules in priority order and evaluates each rule's match conditions (CEL for GCP, NotStatement/OrStatement for AWS, header+path matchRules for URL Map, single block expression for Cloudflare, etc.). Realistic scope: ~9 modules of non-trivial evaluation logic plus a UI surface, ~1 day of focused work for a thorough implementation. Defer until: a user reports they need to verify a specific provider's encoded behaviour against a request they can't easily reason about themselves, or a multi-layer architecture question (like "would request X from IP Y get through both URL Map AND Cloud Armor?") becomes operationally important. Until then, the existing test suite verifies that providers correctly encode the route allowlist, and the route-level lookup answers the operational question.
