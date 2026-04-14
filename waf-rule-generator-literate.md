# WAF Rule Generator:  A Literate Program

*A provider-agnostic tool for defining application URL allowlists and generating Web Application Firewall configurations.*

---

## Motivation

Every web application has a finite set of valid endpoints.  A user registration API exposes `/api/v1/users` for `GET` and `POST`, maybe `/api/v1/users/{id}` for `GET`, `PUT`, and `DELETE`.  A static site serves files under `/static/`.  A health check lives at `/health`.  Everything else -- `/admin`, `/wp-login.php`, `/../../../etc/passwd` -- is noise at best and an attack at worst.

A Web Application Firewall (WAF) should encode this knowledge:  block requests that do not match known routes, enforce method restrictions per route, and apply rate limits where appropriate.  But WAF configurations are deeply provider-specific.  AWS WAF uses nested JSON with byte match statements.  Cloudflare uses a bespoke expression language.  Azure Front Door has its own policy schema.  Nginx uses location blocks and `limit_except` directives.  Terraform wraps all of this in HCL.

The core insight of this tool is simple:  **the route definitions are the source of truth, and the WAF configurations are derived artifacts.**  Define routes once in a canonical, provider-agnostic format.  Generate WAF rules for any target platform mechanically.

This document is that tool, written as a literate program.  The prose explains the design decisions.  The code blocks are the implementation.  Together, they form both the documentation and the software.


## The Canonical Route Schema

Before we can generate anything, we need a data model.  What do we actually know about a route?

At minimum:  a path and which HTTP methods it accepts.  But useful WAF rules need more.  We want to distinguish between exact path matches, prefix matches (like `/static/`), and regex patterns.  We want optional rate limits.  We want tags for grouping and filtering.  We might want to note required headers (like `Authorization`) and expected query parameters, though these are harder to enforce at the WAF layer and serve more as documentation.

Here is the schema:

```javascript
const DEFAULT_ROUTE = {
  path: "",          // The URL path, with parameter placeholders like {id}
  methods: ["GET"],  // Allowed HTTP methods
  description: "",   // Human-readable purpose
  pathType: "exact", // How to match: "exact", "prefix", or "regex"
  queryParams: [],   // Expected query parameters: [{ name, required }]
  headers: [],       // Required headers: [{ name, required }]
  rateLimit: null,   // Requests per minute, or null for no limit
  tags: [],          // Classification tags: ["api", "public", "auth-required"]
};
```

A few design choices deserve explanation.

**Path parameters use curly braces.**  We write `/api/v1/users/{id}`, not `/api/v1/users/:id` (Express style) or `/api/v1/users/<id>` (Flask style).  The OpenAPI convention is the most widely recognized, and the generators need a consistent placeholder format to translate into provider-specific wildcards.  If routes are imported from Express-style source code, the bulk importer normalizes `:param` to `{param}` on the way in.

**`pathType` is explicit rather than inferred.**  We could guess that `/static/` is a prefix match because it ends with a slash, but guessing creates subtle bugs.  A path like `/api/v1/events/` might be exact in one application and a prefix in another.  Making the match type explicit costs one extra field and prevents an entire class of misconfiguration.

**Rate limits are per-minute.**  This is an abstraction.  AWS WAF actually evaluates rate limits over five-minute windows.  Cloudflare uses configurable periods.  Nginx thinks in requests-per-second.  The generators translate from this canonical unit to whatever the provider expects.  The choice of per-minute is pragmatic:  it is coarse enough to be meaningful (unlike per-second, where "3 requests per second" is hard to reason about for humans) and fine enough to be useful (unlike per-hour, which is too loose for most abuse-prevention scenarios).

**Tags are freeform strings.**  We do not predefine categories.  An application might tag routes as `public` vs. `auth-required`, or `v1` vs. `v2`, or `read` vs. `write`.  The tag system is intentionally loose because the groupings that matter differ by organization, and the WAF generators do not depend on specific tag values.  Tags exist for the human operator to filter and review routes before generation.


## Route Discovery

Routes come from two sources, and the tool must handle both.

### White-Box Discovery:  Reading Source Code

When you have access to the source, routes can be extracted programmatically.  Every web framework declares routes in a characteristic pattern:

```
Express:       app.get('/users/:id', handler)
FastAPI:       @app.get("/users/{user_id}")
Spring:        @GetMapping("/users/{id}")
Rails:         get '/users/:id', to: 'users#show'
Django:        path('users/<int:pk>/', views.user_detail)
Flask:         @app.route('/users/<int:id>', methods=['GET'])
Laravel:       Route::get('/users/{id}', [UserController::class, 'show']);
```

A full parser for each framework is out of scope for this tool (and would need to handle dynamic route registration, middleware-injected routes, and other complications).  Instead, the tool provides a bulk import interface that accepts a simple text format:

```
GET /api/v1/users
GET,POST /api/v1/items - Item CRUD
DELETE /api/v1/items/{id}
/health
```

This format is easy to produce from framework-specific tooling.  Most frameworks have a "list routes" command -- `flask routes`, `rails routes`, `php artisan route:list` -- whose output can be massaged into this format with a few lines of shell scripting.

The bulk parser handles three input formats:

```javascript
function parseBulkRoutes(text) {
  const lines = text.split("\n")
    .map(l => l.trim())
    .filter(l => l && !l.startsWith("#"));

  const routes = [];
  for (const line of lines) {
    // Matches these formats:
    //   GET /api/users
    //   GET,POST /api/users  - Description text
    //   /api/users  (defaults to GET)
    const match = line.match(
      /^(?:((?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)
        (?:\s*,\s*(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS))*)
        \s+)?(\S+)(?:\s+-\s+(.*))?$/i
    );

    if (match) {
      const methods = match[1]
        ? match[1].split(",").map(m => m.trim().toUpperCase())
        : ["GET"];
      const path = match[2];
      const desc = match[3] || "";

      // Normalize Express-style :param to OpenAPI-style {param}
      const normalizedPath = path.replace(/:(\w+)/g, "{$1}");

      routes.push({
        ...DEFAULT_ROUTE,
        path: normalizedPath,
        methods,
        description: desc,
        pathType: normalizedPath.endsWith("/")
          && normalizedPath !== "/"
          ? "prefix"
          : "exact",
      });
    }
  }
  return routes;
}
```

The regex is permissive by design.  Lines that do not match are silently skipped, which allows pasting output that includes headers or decorative lines from framework route-listing commands.  Comment lines (starting with `#`) are explicitly filtered.

### Black-Box Discovery:  Observing Traffic

When source code is unavailable, routes must be inferred from observed behavior.  This is inherently incomplete -- you can never be certain you have found every valid route -- but several techniques help:

**Access log analysis.**  Given a representative sample of access logs (from a load balancer, reverse proxy, or application server), extract the unique URI paths.  A simple pipeline:

```bash
# From nginx/apache access logs:
awk '{print $7}' access.log \
  | sed 's/\?.*$//' \
  | sort -u \
  > observed_paths.txt

# From AWS ALB logs:
zcat *.log.gz \
  | awk -F'"' '{print $2}' \
  | awk '{print $2}' \
  | sed 's/\?.*$//' \
  | sort -u \
  > observed_paths.txt
```

**HAR file export.**  Browser developer tools can export HTTP Archive files containing every request made during a session.  These capture AJAX calls, API requests, and resource loads that might not be obvious from the page structure.

**Crawling.**  Tools like `httpx`, `feroxbuster`, or `gospider` can enumerate reachable paths.  This is noisy and will find paths that should be blocked (like leftover debug endpoints), so the output needs curation before import.

**OpenAPI/Swagger discovery.**  Many APIs publish their route definitions at well-known paths (`/swagger.json`, `/openapi.yaml`, `/api-docs`).  If present, these are the most authoritative black-box source.

In all cases, the discovered paths are pasted into the bulk import interface.  The operator reviews and annotates them -- adding method restrictions, setting rate limits, tagging -- before generating WAF rules.  This manual review step is intentional.  Blindly importing observed traffic into WAF rules would allow any path an attacker has already probed.


## WAF Configuration Generators

Each generator takes the same inputs -- an array of routes and a configuration object -- and produces provider-specific output.  The configuration object carries metadata that varies by provider:

```javascript
const config = {
  prefix: "myapp",        // Name prefix for rules and metrics
  scope: "REGIONAL",      // AWS-specific: REGIONAL or CLOUDFRONT
  mode: "Prevention",     // Azure-specific: Prevention or Detection
};
```

The generators share a common strategy:  produce a path allowlist rule (block anything not matching a known route), method enforcement rules (block disallowed methods on known routes), and rate limiting rules (throttle high-frequency endpoints).

### Path Translation

The first problem every generator must solve is translating our canonical path format into something the provider understands.  Path parameters (`{id}`) need to become wildcards or regex patterns.  Prefix matches need trailing wildcards.

For AWS WAF, which uses byte match statements:

```javascript
function pathToAwsPattern(route) {
  // {param} becomes * (AWS WAF wildcard)
  let p = route.path.replace(/\{[^}]+\}/g, "*");

  // Prefix matches get a trailing wildcard
  if (route.pathType === "prefix") {
    p = p.endsWith("/") ? p + "*" : p + "/*";
  }

  return p;
}
```

For Cloudflare, which uses its own expression language:

```javascript
function pathToCloudflareExpr(route) {
  let p = route.path.replace(/\{[^}]+\}/g, "*");

  if (route.pathType === "regex") {
    return `http.request.uri.path matches "${p}"`;
  }
  if (route.pathType === "prefix") {
    return `starts_with(http.request.uri.path, "${p}")`;
  }
  if (p.includes("*")) {
    // Exact match with wildcards needs regex
    return `http.request.uri.path matches "^${p.replace(/\*/g, "[^/]+")}$"`;
  }

  return `http.request.uri.path eq "${p}"`;
}
```

The distinction matters.  Cloudflare's `eq` operator is more efficient than `matches` for exact paths, so we use it when possible and only fall back to regex when the path contains parameter wildcards.


### Generator:  AWS WAF

AWS WAF v2 uses a deeply nested JSON structure.  A Web ACL contains rules, each rule contains a statement tree, and statements compose with `And`, `Or`, and `Not` operators.

The path allowlist rule uses a `NotStatement` wrapping an `OrStatement`:  "block if the path does NOT match any of these patterns."

```javascript
function generateAwsWaf(routes, config) {
  const rules = [];
  const allowPaths = routes.map(r => pathToAwsPattern(r));

  // Rule 1: Block requests to unknown paths
  rules.push({
    Name: `${config.prefix}-allow-known-paths`,
    Priority: 1,
    Action: { Block: {} },
    Statement: {
      NotStatement: {
        Statement: {
          OrStatement: {
            Statements: allowPaths.map(p => ({
              ByteMatchStatement: {
                FieldToMatch: { UriPath: {} },
                PositionalConstraint: p.endsWith("/*")
                  ? "STARTS_WITH"
                  : (p.includes("*") ? "CONTAINS" : "EXACTLY"),
                SearchString: p.replace(/\/?\*$/, ""),
                TextTransformations: [
                  { Priority: 0, Type: "URL_DECODE" },
                  { Priority: 1, Type: "LOWERCASE" }
                ]
              }
            }))
          }
        }
      }
    },
    VisibilityConfig: {
      SampledRequestsEnabled: true,
      CloudWatchMetricsEnabled: true,
      MetricName: `${config.prefix}-path-allowlist`
    }
  });
```

**Text transformations are critical.**  Without `URL_DECODE`, an attacker can bypass the allowlist with percent-encoded paths (`/api/v1/%75sers` instead of `/api/v1/users`).  Without `LOWERCASE`, mixed-case paths might slip through on case-insensitive backends.  We apply both transformations to every byte match statement.

Method enforcement groups routes by their allowed method set to minimize the number of rules:

```javascript
  // Group routes by allowed methods to minimize rule count
  const methodGroups = {};
  routes.forEach(r => {
    const key = r.methods.sort().join(",");
    if (!methodGroups[key]) methodGroups[key] = [];
    methodGroups[key].push(r);
  });

  let priority = 2;
  Object.entries(methodGroups).forEach(([methods, groupRoutes]) => {
    const methodList = methods.split(",");
    rules.push({
      Name: `${config.prefix}-method-enforce-${priority}`,
      Priority: priority++,
      Action: { Block: {} },
      Statement: {
        AndStatement: {
          Statements: [
            // Path matches one of the routes in this group
            { OrStatement: { Statements: groupRoutes.map(r => /* ... */) } },
            // AND method is NOT in the allowed set
            { NotStatement: {
                Statement: { OrStatement: {
                  Statements: methodList.map(m => /* byte match on method */)
                }}
            }}
          ]
        }
      }
    });
  });
```

This grouping is an optimization.  Without it, ten routes with the same method set would produce ten rules.  AWS WAF has a limit of 10 rules per Web ACL (expandable, but at cost), so compressing rules matters.

Rate limiting uses AWS WAF's `RateBasedStatement`.  The important detail is the window conversion:

```javascript
  const rateLimited = routes.filter(r => r.rateLimit);
  rateLimited.forEach(r => {
    rules.push({
      Name: `${config.prefix}-rate-${r.path.replace(/[^a-zA-Z0-9]/g, "-")}`,
      Priority: priority++,
      Action: { Block: {} },
      Statement: {
        RateBasedStatement: {
          Limit: r.rateLimit * 5,  // AWS evaluates over 5-minute windows
          AggregateKeyType: "IP",
          ScopeDownStatement: { /* byte match on the path */ }
        }
      }
    });
  });

  return JSON.stringify({
    Name: `${config.prefix}-web-acl`,
    Scope: config.scope || "REGIONAL",
    DefaultAction: { Allow: {} },
    Rules: rules,
    VisibilityConfig: { /* ... */ }
  }, null, 2);
}
```

The `Limit` multiplication (`rateLimit * 5`) deserves emphasis.  Our canonical rate limit is per-minute.  AWS WAF evaluates rate-based rules over five-minute sliding windows.  A limit of 100 requests per minute becomes 500 in the AWS WAF configuration.  Getting this wrong by a factor of five is a common mistake.


### Generator:  Cloudflare Firewall Rules

Cloudflare's configuration is conceptually simpler.  Each rule has an expression (in Cloudflare's expression language) and an action.

```javascript
function generateCloudflareFw(routes, config) {
  const rules = [];

  // Build a single expression that matches ALL known paths
  const pathExprs = routes.map(r => pathToCloudflareExpr(r));
  const allowExpr = pathExprs.join(" or ");

  // Block anything not in the allowlist
  rules.push({
    description: `[${config.prefix}] Block unknown paths`,
    expression: `not (${allowExpr})`,
    action: "block",
    enabled: true,
  });
```

The elegance of Cloudflare's expression language is that the entire allowlist can be a single rule.  AWS WAF needs an `OrStatement` containing individual `ByteMatchStatements`; Cloudflare just chains `or` operators.

For rate limiting, Cloudflare offers `managed_challenge` as a softer alternative to outright blocking:

```javascript
  const rateLimited = routes.filter(r => r.rateLimit);
  rateLimited.forEach(r => {
    rules.push({
      description: `[${config.prefix}] Rate limit: ${r.path}`,
      expression: pathToCloudflareExpr(r),
      action: "managed_challenge",
      ratelimit: {
        characteristics: ["ip.src"],
        period: 60,
        requests_per_period: r.rateLimit,
        mitigation_timeout: 600,
      },
      enabled: true,
    });
  });

  return JSON.stringify(rules, null, 2);
}
```

Note that `managed_challenge` presents a CAPTCHA or browser challenge rather than returning a hard 403.  This is usually the right choice for rate limiting -- legitimate users who happen to be fast get a speed bump rather than a wall.


### Generator:  Azure Front Door WAF Policy

Azure uses a policy object containing custom rules.  The structure sits between AWS's extreme nesting and Cloudflare's flat simplicity.

```javascript
function generateAzureFd(routes, config) {
  const rules = [];
  let priority = 1;

  // Path allowlist using regex match
  rules.push({
    name: `${config.prefix}AllowKnownPaths`,
    priority: priority++,
    ruleType: "MatchRule",
    action: "Block",
    matchConditions: [{
      matchVariable: "RequestUri",
      operator: "RegEx",
      negateCondition: true,
      matchValue: routes.map(r => {
        let p = r.path.replace(/\{[^}]+\}/g, "[^/]+");
        if (r.pathType === "prefix") return `^${p}.*`;
        return `^${p}$`;
      }),
      transforms: ["UrlDecode", "Lowercase"]
    }]
  });
```

Azure's `matchValue` is an array of patterns that are implicitly OR-ed, which keeps the rule compact.  The `negateCondition: true` inverts the match:  "block if the URI does NOT match any of these patterns."

Rate limiting in Azure Front Door uses `RateLimitRule` with a five-minute window (like AWS):

```javascript
  rateLimited.forEach(r => {
    rules.push({
      name: `${config.prefix}Rate${r.path.replace(/[^a-zA-Z0-9]/g, "")}`,
      priority: priority++,
      ruleType: "RateLimitRule",
      action: "Block",
      rateLimitThreshold: r.rateLimit * 5,  // 5-minute window, same as AWS
      rateLimitDurationInMinutes: 5,
      matchConditions: [{ /* regex on path */ }]
    });
  });

  return JSON.stringify({
    properties: {
      customRules: { rules },
      policySettings: {
        mode: config.mode || "Prevention",
        enabledState: "Enabled"
      }
    }
  }, null, 2);
}
```


### Generator:  Nginx

Nginx is not a cloud WAF, but it is often the first line of defense.  Its configuration is declarative text rather than JSON, so the generator produces a config file:

```javascript
function generateNginx(routes, config) {
  let out = `# WAF-style allowlist for ${config.prefix}\n`;
  out += `# Generated ${new Date().toISOString()}\n\n`;

  // Step 1: A map directive that validates paths
  out += `map $request_uri $valid_path {\n  default 0;\n`;
  routes.forEach(r => {
    let pat = r.path.replace(/\{[^}]+\}/g, "[^/]+");
    if (r.pathType === "prefix") pat = `~^${pat}`;
    else if (pat.includes("[^/]+")) pat = `~^${pat}$`;
    out += `  ${pat}  1;\n`;
  });
  out += `}\n\n`;

  // Step 2: Block unknown paths
  out += `server {\n`;
  out += `  if ($valid_path = 0) {\n    return 403;\n  }\n\n`;

  // Step 3: Per-location method restrictions
  routes.forEach(r => {
    let loc = r.path.replace(/\{[^}]+\}/g, "[^/]+");
    const directive = loc.includes("[^/]+") || r.pathType === "prefix"
      ? `location ~ ${r.pathType === "prefix" ? `^${loc}` : `^${loc}$`}`
      : `location = ${r.path}`;

    out += `  ${directive} {\n`;
    out += `    limit_except ${r.methods.join(" ")} {\n`;
    out += `      deny all;\n    }\n`;

    if (r.rateLimit) {
      const zoneName = `${config.prefix}_${r.path.replace(/[^a-zA-Z0-9]/g, "_")}`;
      out += `    limit_req zone=${zoneName} `;
      out += `burst=${Math.ceil(r.rateLimit * 0.2)} nodelay;\n`;
    }

    out += `    proxy_pass http://upstream;\n`;
    out += `  }\n\n`;
  });

  out += `}\n`;
  return out;
}
```

The Nginx generator uses `map` for the initial path validation because it is evaluated once per request and is more efficient than chaining `if` directives.  The `limit_except` directive inside each `location` block is Nginx's idiomatic way to restrict HTTP methods -- it allows the listed methods and denies everything else.

The burst parameter for rate limiting is set to 20% of the per-minute limit.  This allows short bursts of legitimate traffic (a user clicking through several pages quickly) while still throttling sustained abuse.  The `nodelay` flag prevents request queuing, which would add latency rather than rejecting excess requests.


### Generator:  Terraform (AWS WAF)

The Terraform generator produces the same logical rules as the AWS WAF JSON generator, but in HashiCorp Configuration Language (HCL).  This is the format most teams will actually deploy, since infrastructure-as-code is the standard practice for WAF management.

```javascript
function generateTerraformAws(routes, config) {
  let out = `resource "aws_wafv2_web_acl" "${config.prefix}_acl" {\n`;
  out += `  name        = "${config.prefix}-web-acl"\n`;
  out += `  scope       = "${config.scope || "REGIONAL"}"\n\n`;
  out += `  default_action {\n    allow {}\n  }\n\n`;

  // Path allowlist rule
  out += `  rule {\n`;
  out += `    name     = "${config.prefix}-path-allowlist"\n`;
  out += `    priority = 1\n\n`;
  out += `    action {\n      block {}\n    }\n\n`;
  out += `    statement {\n`;
  out += `      not_statement {\n`;
  out += `        statement {\n`;
  out += `          or_statement {\n`;

  routes.forEach(r => {
    const p = pathToAwsPattern(r);
    const constraint = p.endsWith("/*")
      ? "STARTS_WITH"
      : (p.includes("*") ? "CONTAINS" : "EXACTLY");

    out += `            byte_match_statement {\n`;
    out += `              field_to_match { uri_path {} }\n`;
    out += `              positional_constraint = "${constraint}"\n`;
    out += `              search_string         = "${p.replace(/\/?\*$/, "")}"\n`;
    out += `              text_transformation {\n`;
    out += `                priority = 0\n`;
    out += `                type     = "URL_DECODE"\n`;
    out += `              }\n`;
    out += `            }\n`;
  });

  out += `          }\n        }\n      }\n    }\n`;
  out += `  }\n`;
  out += `}\n`;

  return out;
}
```


## The Export Format

The canonical route schema is also the export format.  When you export routes, you get a JSON file that contains a version number, a timestamp, and the array of routes:

```json
{
  "version": "1.0",
  "exported": "2026-04-13T14:30:00.000Z",
  "routes": [
    {
      "path": "/api/v1/users",
      "methods": ["GET", "POST"],
      "pathType": "exact",
      "description": "User listing and creation",
      "queryParams": [
        { "name": "page", "required": false },
        { "name": "limit", "required": false }
      ],
      "headers": [
        { "name": "Authorization", "required": true }
      ],
      "rateLimit": 100,
      "tags": ["api", "auth-required"]
    }
  ]
}
```

This file should be checked into version control alongside your application code.  When the application adds or removes routes, update the route definitions.  When you need WAF rules for a new provider, generate them from the same file.  The routes file is the single source of truth; the WAF configurations are disposable outputs.

The version field exists to support future schema evolution.  If we add fields (like request body validation or IP allowlists per route), the version number allows import logic to handle old and new formats gracefully.


## Extending the System

Several directions are natural next steps.

**Source code parsers.**  Rather than relying on framework route-listing commands, a dedicated parser could read Express `app.get()` calls, FastAPI `@app.get` decorators, Spring `@RequestMapping` annotations, or Rails `config/routes.rb` directly.  Each parser would produce the canonical route array.  The challenge is handling dynamic route registration, middleware-injected routes, and metaprogramming -- which is why the initial version opts for the simpler bulk-import approach.

**OpenAPI import.**  If an application publishes an OpenAPI (Swagger) specification, it already contains path definitions, method restrictions, and parameter schemas in a standardized format.  An OpenAPI importer would be the highest-fidelity route discovery mechanism.

**Additional providers.**  Akamai and Fastly each have their own WAF configuration formats.  The generator architecture (a function that takes routes and config, returns a string) makes adding new providers straightforward.  GCP Cloud Armor, Coraza/ModSecurity, and OWASP ZAP have already been added using this pattern.

**Drift detection.**  Given access to both the route definition file and the deployed WAF configuration, a diff tool could detect when they diverge -- routes added to the application but not to the WAF, or stale WAF rules for routes that no longer exist.

**CI/CD integration.**  The generation logic can run in a pipeline:  on each deploy, re-extract routes from source code, compare against the stored route definitions, and regenerate WAF rules if anything changed.  The generated rules can be applied via the provider's API or Terraform.


## Summary

The WAF Rule Generator separates two concerns that are usually tangled together:  knowing what your application exposes, and telling your WAF about it.  The canonical route schema captures the first concern in a provider-agnostic format.  The generators handle the second, translating that knowledge into AWS WAF JSON, Cloudflare expressions, Azure Front Door policies, GCP Cloud Armor policies, Nginx configs, Caddy configs, Coraza/ModSecurity SecRule directives, and OWASP ZAP automation test plans.

The literate structure of this document is intentional.  WAF rules are security-critical infrastructure.  Understanding *why* a rule is shaped the way it is -- why text transformations are applied, why rate limits are multiplied by five, why method groups are compressed -- matters as much as having the rule in the first place.  When the next engineer inherits this system, the prose and the code are in the same place.
