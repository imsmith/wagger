# Wagger

*A provider-agnostic route-to-policy compiler for Web Application Firewall configurations, written in Elixir.*

---

## Motivation

Every web application has a finite set of valid endpoints.  A user registration API exposes `/api/v1/users` for `GET` and `POST`, maybe `/api/v1/users/{id}` for `GET`, `PUT`, and `DELETE`.  A static site serves files under `/static/`.  A health check lives at `/health`.  Everything else -- `/admin`, `/wp-login.php`, `/../../../etc/passwd` -- is noise at best and an attack at worst.

A Web Application Firewall (WAF) should encode this knowledge:  block requests that do not match known routes, enforce method restrictions per route, and apply rate limits where appropriate.  But WAF configurations are deeply provider-specific.  AWS WAF uses nested JSON with byte match statements.  Cloudflare uses a bespoke expression language.  Azure Front Door has its own policy schema.  Nginx uses location blocks and `limit_except` directives.  Coraza uses SecRule directives.  Each requires different structure, different escaping, different semantics for the same logical intent.

The core insight of this tool is simple:  **the route definitions are the source of truth, and the WAF configurations are derived artifacts.**  Define routes once in a canonical, provider-agnostic format.  Generate WAF rules for any target platform mechanically.  Detect when the two diverge.

This document is that tool, written as a literate program.  The prose explains the design decisions.  The code blocks are the implementation.  Together, they form both the documentation and the software.

The original version of this document was written in JavaScript.  This is the Elixir rewrite -- a Phoenix application called Wagger, with a persistent data model, a YANG-validated generation pipeline, drift detection, a public Hub for sharing API definitions, and integration with the Comn infrastructure library.


## The Canonical Route Schema

Before we can generate anything, we need a data model.  What do we actually know about a route?

At minimum:  a path and which HTTP methods it accepts.  But useful WAF rules need more.  We want to distinguish between exact path matches, prefix matches (like `/static/`), and regex patterns.  We want optional rate limits.  We want tags for grouping and filtering.  We might want to note required headers and expected query parameters, though these are harder to enforce at the WAF layer and serve more as documentation.

Here is the Ecto schema:

```elixir
schema "routes" do
  field :path, :string               # URL path, with {param} placeholders
  field :methods, Wagger.Ecto.EdnList # Allowed HTTP methods, stored as EDN
  field :path_type, :string           # "exact", "prefix", or "regex"
  field :description, :string
  field :query_params, Wagger.Ecto.EdnMapList
  field :headers, Wagger.Ecto.EdnMapList
  field :rate_limit, :integer         # Requests per minute, or nil
  field :tags, Wagger.Ecto.EdnList    # Classification tags
  belongs_to :application, Wagger.Applications.Application
end
```

Routes are grouped under Applications -- each application represents one web service.  Applications have a name (a unique slug), a description, an optional source (where the routes were imported from), a route checksum (SHA-256, auto-updated on mutations), and visibility controls (`public` and `shareable` flags for the Hub).

A few design choices deserve explanation.

**Path parameters use curly braces.**  We write `/api/v1/users/{id}`, not `/api/v1/users/:id` (Express style) or `/api/v1/users/<id>` (Flask style).  The OpenAPI convention is the most widely recognized, and the generators need a consistent placeholder format to translate into provider-specific wildcards.  If routes are imported from Express-style source code, the bulk importer normalizes `:param` to `{param}` on the way in.

**`path_type` is explicit rather than inferred.**  We could guess that `/static/` is a prefix match because it ends with a slash, but guessing creates subtle bugs.  A path like `/api/v1/events/` might be exact in one application and a prefix in another.  Making the match type explicit costs one extra field and prevents an entire class of misconfiguration.

**Rate limits are per-minute.**  This is an abstraction.  AWS WAF evaluates rate limits over five-minute windows.  Cloudflare uses configurable periods.  Nginx thinks in requests-per-second.  The generators translate from this canonical unit to whatever the provider expects.  The choice of per-minute is pragmatic:  it is coarse enough to be meaningful (unlike per-second, where "3 requests per second" is hard to reason about for humans) and fine enough to be useful (unlike per-hour, which is too loose for most abuse-prevention scenarios).

**EDN for list storage.**  Methods, tags, query parameters, and headers are stored as EDN text in SQLite, parsed on read by custom Ecto types.  This avoids the complexity of join tables for simple list data while keeping the storage human-readable.  The choice of EDN over JSON is deliberate:  EDN is the preferred serialization format in this stack, and it supports a richer set of types.


## Route Discovery

Routes come from three sources, and the tool handles all of them.

### Bulk Text Import

When you have access to the source, routes can be extracted from framework route-listing commands (`flask routes`, `rails routes`, `php artisan route:list`) and pasted into the import interface.  The bulk parser accepts a simple text format:

```
GET /api/v1/users
GET,POST /api/v1/items - Item CRUD
DELETE /api/v1/items/{id}
/health
```

The parser is permissive by design:

```elixir
defmodule Wagger.Import.Bulk do
  @method_chars ~r/^([A-Za-z,]+)\s+(\/\S*)\s*(?:-\s*(.+))?$/
  @path_only ~r/^(\/\S*)\s*(?:-\s*(.+))?$/

  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> skip?(line) end)
    |> Enum.reduce({[], []}, fn {line, n}, {routes, skipped} ->
      case parse_line(line) do
        {:ok, route} -> {[route | routes], skipped}
        :error -> {routes, [skipped_entry(n, line) | skipped]}
      end
    end)
    |> then(fn {routes, skipped} -> {Enum.reverse(routes), Enum.reverse(skipped)} end)
  end
end
```

Lines that do not match either pattern are collected in the `skipped` list rather than raising an error.  This allows pasting output that includes headers or decorative lines from framework route-listing commands.  Comment lines (starting with `#`) and blank lines are filtered before parsing.  Express-style `:param` segments are normalized to `{param}` via regex replacement.

### OpenAPI Import

If an application publishes an OpenAPI 3.x specification, it already contains path definitions, method restrictions, parameter schemas, and descriptions in a standardized format.  The OpenAPI importer extracts all of this:

```elixir
defmodule Wagger.Import.OpenApi do
  @http_methods ~w(get post put patch delete head options)

  def parse(spec) when is_map(spec) do
    case Map.fetch(spec, "paths") do
      :error -> {[], ["No paths found in OpenAPI spec"]}
      {:ok, paths} -> {parse_paths(paths), []}
    end
  end
end
```

For each path in the spec, the importer iterates over known HTTP method keys, extracts descriptions from `summary` or `description` fields, and collects query and header parameters with their required flags.  The suggested application name is derived from the spec's `info.title` field.

### Access Log Import

When source code is unavailable, routes can be inferred from observed traffic.  The access log parser supports nginx/Apache combined format, Caddy JSON logs, and AWS ALB logs:

```elixir
defmodule Wagger.Import.AccessLog do
  @nginx_re ~r/"([A-Z]+) ([^\s"]+) HTTP\/[\d.]+"/

  def parse(input) when is_binary(input) do
    # Auto-detects format per line: JSON lines → Caddy, quoted request → nginx/ALB
    # Groups by path, accumulates distinct methods and request count
    # Returns routes sorted by count descending
  end
end
```

Paths are stripped of query strings.  Requests to the same path are grouped together, accumulating distinct methods and a total count.  Routes are returned sorted by request count descending, giving the operator a frequency-ranked view of the observed API surface.

This discovery method is inherently incomplete -- you can never be certain you have found every valid route from logs alone.  The operator reviews and annotates the discovered routes before importing.  This manual review step is intentional:  blindly importing observed traffic into WAF rules would allow any path an attacker has already probed.


## The Generation Pipeline

The heart of Wagger is a three-stage pipeline that transforms routes into provider-specific output.  Every generator implements the same behaviour:

```elixir
defmodule Wagger.Generator do
  @callback yang_module() :: String.t()
  @callback map_routes(routes :: [map()], config :: map()) :: map()
  @callback serialize(instance :: map(), schema :: struct()) :: String.t()
end
```

The shared `generate/3` function orchestrates the pipeline:

```elixir
def generate(provider_module, routes, config) do
  yang_source = provider_module.yang_module()

  with {:ok, parsed} <- ExYang.parse(yang_source),
       {:ok, resolved} <- ExYang.resolve(parsed, %{}),
       instance = provider_module.map_routes(routes, config),
       :ok <- Validator.validate(instance, resolved) do
    output = provider_module.serialize(instance, resolved)
    {:ok, output}
  end
end
```

**Stage 1: YANG schema.**  Each provider defines a YANG model describing the structure of its intermediate representation.  YANG gives us formal type checking, mandatory field enforcement, enum validation, and list key uniqueness -- all verified before serialization.

**Stage 2: Instance tree.**  `map_routes/2` transforms the flat route list into a nested map that conforms to the provider's YANG schema.  This is where provider-specific logic lives:  path translation, method grouping, rate limit conversion, rule ID allocation.

**Stage 3: Serialization.**  `serialize/2` converts the validated instance tree to the provider's native format -- JSON for cloud WAFs, text for Nginx/Caddy/Coraza, YAML for ZAP.

This architecture has a useful property:  the YANG validation step catches structural bugs in the generator before they produce invalid output.  If a generator forgets a mandatory field or uses an invalid enum value, the pipeline rejects it before serialization.


### Path Translation

The first problem every generator must solve is translating canonical path format into something the provider understands.  A shared `PathHelper` module handles the common transformations:

```elixir
defmodule Wagger.Generator.PathHelper do
  def to_regex(%{path: path, path_type: "exact"}) do
    converted = String.replace(path, ~r/\{[^}]+\}/, "[^/]+")
    "^#{converted}$"
  end

  def to_regex(%{path: path, path_type: "prefix"}) do
    converted = String.replace(path, ~r/\{[^}]+\}/, "[^/]+")
    "^#{converted}.*"
  end

  def to_regex(%{path: path, path_type: "regex"}), do: path

  def to_wildcard(%{path: path, path_type: "exact"}) do
    String.replace(path, ~r/\{[^}]+\}/, "*")
  end
end
```

The `to_regex/1` function anchors patterns:  exact paths get `^...$`, prefix paths get `^....*`, regex paths pass through unchanged.  The `to_wildcard/1` function replaces `{param}` with `*` for providers like AWS WAF that use glob-style matching.  The `to_nginx_location/1` function returns a `{match_type, pattern}` tuple for Nginx's three location directive forms: `=` for exact, `~` for regex, and bare path for prefix.


### Generator:  AWS WAF

AWS WAF v2 uses a deeply nested JSON structure.  A Web ACL contains rules, each rule contains a statement tree, and statements compose with `And`, `Or`, and `Not` operators.

```elixir
defmodule Wagger.Generator.Aws do
  @behaviour Wagger.Generator

  @standard_transforms [
    %{"Priority" => 0, "Type" => "URL_DECODE"},
    %{"Priority" => 1, "Type" => "LOWERCASE"}
  ]

  def map_routes(routes, config) do
    prefix = config[:prefix] || config["prefix"]
    scope = config[:scope] || config["scope"] || "REGIONAL"
    normalized = Enum.map(routes, &normalize/1)

    path_patterns = Enum.map(normalized, &to_path_pattern/1)
    allowlist_rule = %{"name" => "#{prefix}-path-allowlist", "priority" => 1, ...}
    method_rules = build_method_rules(normalized, prefix, starting_priority: 10)
    rate_rules = build_rate_rules(normalized, prefix, starting_priority: 100)

    %{"aws-waf-config" => %{
      "web-acl-name" => "#{prefix}-web-acl",
      "scope" => scope,
      "rules" => [allowlist_rule] ++ method_rules ++ rate_rules
    }}
  end
end
```

**Text transformations are critical.**  Without `URL_DECODE`, an attacker can bypass the allowlist with percent-encoded paths (`/api/v1/%75sers` instead of `/api/v1/users`).  Without `LOWERCASE`, mixed-case paths might slip through on case-insensitive backends.  Both transformations are applied to every byte match and regex match statement.

**Method enforcement groups routes by their allowed method set** to minimize rule count.  Without grouping, ten routes with the same method set would produce ten rules.  AWS WAF has a limit of 10 rules per Web ACL (expandable, but at cost), so compressing rules matters.

**Rate limit window conversion** deserves emphasis.  The canonical rate limit is per-minute.  AWS WAF evaluates rate-based rules over five-minute sliding windows.  A limit of 100 requests per minute becomes 500 in the AWS configuration:

```elixir
defp build_rate_rules(normalized, prefix, starting_priority: base) do
  normalized
  |> Enum.filter(&(not is_nil(&1.rate_limit)))
  |> Enum.with_index()
  |> Enum.map(fn {route, idx} ->
    %{
      "name" => "#{prefix}-rate-limit-#{sanitize(route.path)}",
      "priority" => base + idx,
      "rule-type" => "rate-limit",
      "rate-limit" => route.rate_limit * 5
    }
  end)
end
```

Getting this wrong by a factor of five is a common mistake.


### Generator:  Cloudflare Firewall Rules

Cloudflare's configuration is conceptually simpler.  Each rule has an expression (in Cloudflare's expression language) and an action.  The elegance of the expression language is that the entire allowlist can be a single rule:  `not (path1 or path2 or ...)`.  AWS WAF needs an `OrStatement` containing individual `ByteMatchStatements`; Cloudflare just chains `or` operators.

Cloudflare distinguishes between match operators:  `eq` for exact paths (most efficient), `starts_with` for prefix matches, and `matches` for regex.  The generator uses `eq` when possible and only falls back to regex when the path contains parameter wildcards.

For rate limiting, Cloudflare offers `managed_challenge` as a softer alternative to outright blocking.  This presents a CAPTCHA or browser challenge rather than returning a hard 403 -- usually the right choice for rate limiting, since legitimate users who happen to be fast get a speed bump rather than a wall.


### Generator:  Azure Front Door WAF Policy

Azure uses a policy object containing custom rules.  The structure sits between AWS's extreme nesting and Cloudflare's flat simplicity.  Azure's `matchValue` is an array of regex patterns that are implicitly OR-ed, keeping the path allowlist rule compact.  The `negateCondition: true` flag inverts the match:  "block if the URI does NOT match any of these patterns."

Rate limiting in Azure Front Door uses `RateLimitRule` with a five-minute window, same as AWS.  The same multiplication factor applies.


### Generator:  GCP Cloud Armor

GCP Cloud Armor uses security policies with CEL (Common Expression Language) expressions for path matching.  The generator produces a JSON security policy document with path-based rules.


### Generator:  Nginx

Nginx is not a cloud WAF, but it is often the first line of defense.  Its configuration is declarative text rather than JSON:

```elixir
defmodule Wagger.Generator.Nginx do
  @behaviour Wagger.Generator

  def serialize(instance, _schema) do
    cfg = instance["nginx-config"]
    # Produces:
    # 1. A `map` directive for path validation (blocks unknown paths with 403)
    # 2. `location` blocks with `limit_except` for method enforcement
    # 3. Optional `limit_req` rate limiting per location
    # 4. `proxy_pass` to upstream
  end
end
```

The Nginx generator uses `map` for the initial path validation because it is evaluated once per request and is more efficient than chaining `if` directives.  The `limit_except` directive inside each `location` block is Nginx's idiomatic way to restrict HTTP methods -- it allows the listed methods and denies everything else.

The burst parameter for rate limiting is set to 20% of the per-minute limit.  This allows short bursts of legitimate traffic while still throttling sustained abuse.  The `nodelay` flag prevents request queuing, which would add latency rather than rejecting excess requests.


### Generator:  Caddy

The Caddy generator produces a Caddyfile with named matcher blocks (`@name`) using `path` or `path_regexp` directives, `route` blocks with `reverse_proxy` and optional `rate_limit`, and a catch-all `respond 403` to block unmatched requests.  Similar to Nginx but with Caddy's declarative matcher syntax.


### Generator:  Coraza/ModSecurity

Coraza is the open-source ModSecurity-compatible WAF from OWASP.  Its only configuration language is SecLang -- the same directive language as ModSecurity.  There is no separate "native" format.

The generator produces a standalone `.conf` file:

```elixir
defmodule Wagger.Generator.Coraza do
  @behaviour Wagger.Generator

  @default_start_rule_id 100_001
  @catch_all_offset 90_000

  def map_routes(routes, config) do
    start_id = parse_int(config, "start_rule_id", @default_start_rule_id)
    rule_engine = config[:rule_engine] || config["rule_engine"] || "On"

    rules = routes
      |> Enum.with_index()
      |> Enum.map(fn {route, idx} ->
        %{
          "id" => start_id + idx,
          "path-pattern" => PathHelper.to_regex(normalize(route)),
          "methods" => normalize(route).methods
        }
      end)

    %{"coraza-config" => %{
      "rule-engine" => rule_engine,
      "start-rule-id" => start_id,
      "rules" => rules,
      "catch-all-rule-id" => start_id + @catch_all_offset
    }}
  end
end
```

Each route becomes a `SecRule REQUEST_URI` with `@rx` regex matching, chained with a `SecRule REQUEST_METHOD` using `@pm` (phrase match) for method enforcement.  The output looks like:

```
SecRuleEngine On
SecRequestBodyAccess On
SecDefaultAction "phase:1,log,auditlog,deny,status:403"

# GET POST /api/users — Users
SecRule REQUEST_URI "@rx ^/api/users$" "id:100001,phase:1,chain,allow"
  SecRule REQUEST_METHOD "@pm GET POST" "t:none"

# Deny all undeclared paths
SecRule REQUEST_URI "@rx .*" "id:190001,phase:1,deny,status:403,msg:'No matching route'"
```

Key decisions:  all enforcement in phase 1 (request headers, cheapest and earliest).  Rate limits are emitted as comments since ModSecurity lacks native per-path rate limiting.  Rule IDs are configurable (default 100001) to avoid collisions with existing rulesets.  The catch-all deny rule gets ID `start + 90000`.


### Generator:  OWASP ZAP Automation Plan

The ZAP generator is different from the others:  it does not produce WAF configuration.  Instead, it produces a test plan that *verifies* a deployed WAF configuration is working correctly.

The output is an OWASP ZAP automation framework YAML plan with three `requestor` jobs:

```elixir
defmodule Wagger.Generator.Zap do
  @behaviour Wagger.Generator

  @all_methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  @bad_paths [
    {"/nonexistent", "Undeclared path"},
    {"/api/../etc/passwd", "Path traversal attempt"},
    {"//double-slash", "Double slash"},
    {"/%00null", "Null byte injection"}
  ]

  defp build_positive_tests(routes, target_url) do
    # For each route, for each allowed method: expect non-403
  end

  defp build_negative_method_tests(routes, target_url) do
    # For each route, for each disallowed method: expect 403
  end

  defp build_negative_path_tests(target_url) do
    # Fixed set of synthetic bad paths: expect 403
  end
end
```

**Positive tests** confirm that declared routes with allowed methods return non-403.  **Negative method tests** confirm that disallowed methods on declared routes return 403.  **Negative path tests** probe a fixed set of synthetic bad paths (path traversal, null bytes, double slashes) to verify the catch-all deny works.

Path parameters are expanded to example values (`{id}` becomes `1`) so the URLs are concrete.  The target URL is configurable, falling back to a `{{TARGET_URL}}` placeholder if not provided.


## YANG as Intermediate Schema

Each provider has a YANG model defining the structure of its instance data tree.  A shared `wagger-common.yang` defines reusable types:

```yang
module wagger-common {
  typedef http-method {
    type enumeration { enum "GET"; enum "POST"; enum "PUT"; ... }
  }
  typedef path-type {
    type enumeration { enum "exact"; enum "prefix"; enum "regex"; }
  }
  typedef rate-limit {
    type uint32 { range "1..1000000"; }
  }
}
```

Provider schemas define the container structure for their intermediate representation.  For example, the Coraza YANG model:

```yang
module wagger-coraza {
  container coraza-config {
    leaf config-name { type string; mandatory true; }
    leaf rule-engine { type enumeration { enum "On"; enum "Off"; enum "DetectionOnly"; } }
    leaf start-rule-id { type uint32; mandatory true; }
    list rules {
      key "id";
      leaf id { type uint32; mandatory true; }
      leaf path-pattern { type string; mandatory true; }
      leaf-list methods { type string; }
    }
    leaf catch-all-rule-id { type uint32; mandatory true; }
  }
}
```

The `Wagger.Generator.Validator` module walks the instance data against the resolved YANG schema, checking mandatory fields, type correctness, enum values, list key presence, and duplicate detection.  This catches generator bugs at development time rather than deployment time.


## Drift Detection

Once a WAF configuration has been generated from a set of routes, the routes may change:  new endpoints added, old ones removed, rate limits adjusted.  Wagger detects this drift by comparing the current route state against the last generation snapshot.

```elixir
defmodule Wagger.Drift do
  def detect(%Application{} = app, provider) do
    current_routes = Routes.list_routes(app)
    normalized = normalize_for_snapshot(current_routes)
    current_checksum = compute_checksum(normalized)

    case Snapshots.latest_snapshot(app, provider) do
      nil -> %Drift{status: :never_generated}
      snapshot when snapshot.checksum == current_checksum ->
        %Drift{status: :current}
      snapshot ->
        changes = structural_diff(normalized, decode_snapshot(snapshot.route_snapshot))
        %Drift{status: :drifted, changes: changes}
    end
  end
end
```

**Fast path:**  SHA-256 checksum comparison.  Routes are sorted by path, serialized to Erlang binary format, and hashed.  If the checksum matches the snapshot, no diff is needed.

**Structural diff:**  If checksums differ, the two route sets are diffed by path.  The result is `%{added: [...], removed: [...], modified: [...]}`.  Modified routes are those where the path exists in both sets but the methods, path type, or rate limit has changed.

Drift is computed on demand, not polled.  The dashboard shows drift status for every app-provider pair, color-coded:  green for current, amber for drifted (with change count), grey for never generated.


## Snapshots and Encryption

Every generation creates an immutable snapshot:  the provider, config parameters, frozen route data, generated output, and a checksum.  Snapshots are the audit trail for what was generated, when, and from what input.

The output field is encrypted at rest using `Comn.Secrets.Local` (ChaCha20-Poly1305 AEAD with an Ed25519-derived key):

```elixir
defmodule Wagger.Secrets do
  alias Comn.Secrets.{Key, Local}

  def lock(plaintext) when is_binary(plaintext) do
    key = get_or_create_key()
    case Local.lock(plaintext, key) do
      {:ok, locked} -> {:ok, locked |> :erlang.term_to_binary() |> Base.encode64()}
      {:error, _} = err -> err
    end
  end
end
```

The encryption key is auto-generated on first use and stored at `priv/secrets/wagger.key` (gitignored).  Decryption falls back gracefully to raw output for snapshots created before encryption was enabled.

Snapshots also record `request_id` and `generated_by` from the ambient `Comn.Contexts`, providing audit trail linkage back to the authenticated user and request that triggered the generation.


## The Public Hub

Applications marked `public` and `shareable` are published to the Hub at `/hub`.  The Hub is read-only and requires no authentication:  anyone can browse published API definitions, view route treemaps, and generate WAF configs.

The Hub addresses applications by name slug (`/hub/petstore-api`) rather than numeric ID, since these are public-facing URLs that should be stable and human-readable.

The `shareable` flag requires `public` -- toggling `public` off forces `shareable` off.  This prevents the accidental state of a private but shareable application.


## Error Handling

Wagger uses `Comn.Errors.Registry` for machine-readable error codes.  Each error is declared at compile time with a namespace, category, default message, and optional HTTP status:

```elixir
defmodule Wagger.Errors do
  use Comn.Errors.Registry

  register_error "wagger.generator/validation_failed", :validation,
    message: "Instance data failed YANG schema validation"

  register_error "wagger.generator/unknown_provider", :validation,
    message: "Unknown provider name", status: 400

  register_error "wagger.accounts/auth_failed", :auth,
    message: "Invalid or missing API key", status: 401

  register_error "wagger.applications/protected", :auth,
    message: "Cannot delete a protected application", status: 403
end
```

At runtime, errors are created via `Comn.Errors.Registry.error!/2`, which produces a `Comn.Errors.ErrorStruct` enriched with ambient context (request ID, trace ID, correlation ID).  The fallback controller renders these as structured JSON with the registered HTTP status.


## Event Broadcasting

Route mutations, application changes, and generation events are broadcast through `Comn.EventBus` (Registry-based pub/sub) and recorded in `Comn.EventLog` (in-memory append-only log):

```elixir
defmodule Wagger.Events do
  alias Comn.Events.EventStruct

  def route_changed(action, route) when action in [:created, :updated, :deleted] do
    emit(:route, "wagger.route.#{action}", %{
      path: route.path,
      application_id: route.application_id,
      methods: route.methods
    })
  end

  def config_generated(app, provider, snapshot_id) do
    emit(:generation, "wagger.config.generated", %{
      application_id: app.id,
      provider: provider,
      snapshot_id: snapshot_id
    })
  end
end
```

Events are automatically enriched with the actor from the ambient `Comn.Contexts` when available.  The `EventStruct` auto-pulls `request_id` and `correlation_id` from the process dictionary.


## Extending the System

Several directions are natural next steps.

**Source code parsers.**  Rather than relying on framework route-listing commands, a dedicated parser could read Express `app.get()` calls, FastAPI `@app.get` decorators, Spring `@RequestMapping` annotations, or Rails `config/routes.rb` directly.

**Terraform providers.**  The generator pipeline is not WAF-specific.  It takes routes and produces text.  Terraform HCL wrapping any of the existing providers is a natural next target, as are Kubernetes Ingress manifests, Envoy VirtualService configs, and API Gateway definitions.

**Hub federation.**  The current Hub is local to a single Wagger instance.  A central registry that multiple instances push to and pull from would enable cross-organization API definition sharing.

**Hub derive.**  Select a subset of routes from a published application and derive a scoped policy -- for example, an egress policy that permits only GETs to specific paths.

**CI/CD integration.**  The generation logic can run in a pipeline:  on each deploy, re-extract routes from source code, compare against the stored route definitions, and regenerate WAF rules if anything changed.


## Summary

Wagger separates two concerns that are usually tangled together:  knowing what your application exposes, and telling your WAF about it.  The canonical route schema captures the first concern in a provider-agnostic format.  Eight generators handle the second, translating that knowledge into AWS WAF JSON, Cloudflare expressions, Azure Front Door policies, GCP Cloud Armor policies, Nginx configs, Caddy configs, Coraza/ModSecurity SecRule directives, and OWASP ZAP automation test plans.

The YANG validation layer catches structural bugs before they become misconfigurations.  The drift detection system catches temporal bugs -- routes that changed after the WAF was configured.  The snapshot audit trail records what was generated, when, by whom, encrypted at rest.  The Hub makes API definitions shareable.  The Comn integration provides structured errors, request context propagation, event broadcasting, and encryption.

The literate structure of this document is intentional.  WAF rules are security-critical infrastructure.  Understanding *why* a rule is shaped the way it is -- why text transformations are applied, why rate limits are multiplied by five, why method groups are compressed -- matters as much as having the rule in the first place.  When the next engineer inherits this system, the prose and the code are in the same place.
