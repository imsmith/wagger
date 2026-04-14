# Remaining Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement 5 remaining WAF config generators (AWS, Cloudflare, Azure, GCP, Caddy) following the proven YANG-validated pattern established by the Nginx generator.

**Architecture:** Each provider follows the identical pattern: YANG model defining the provider's config structure → generator module implementing `Wagger.Generator` behaviour (yang_module/0, map_routes/2, serialize/2) → tests validating both the mapping and full pipeline. Cloud providers (AWS, Cloudflare, Azure, GCP) serialize to JSON. Caddy serializes to Caddyfile text.

**Tech Stack:** Elixir, ex_yang, Jason (for JSON serialization), existing PathHelper.

---

## Proven Pattern Reference

Each generator follows the Nginx template at `lib/wagger/generator/nginx.ex`:

1. `yang_module/0` — reads the YANG file from `yang/wagger-<provider>.yang`
2. `map_routes/2` — normalizes routes (handle atom/string keys), uses PathHelper for path translation, builds a map conforming to the YANG model
3. `serialize/2` — converts the validated instance tree to the provider's native format

**All 5 providers are independent** and can be implemented in parallel.

## Shared Test Routes

Every provider test uses the same route set:

```elixir
@routes [
  %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
  %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
  %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
  %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
]
```

---

### Task 1: AWS WAF Generator

**Files:**
- Create: `yang/wagger-aws-waf.yang`
- Create: `lib/wagger/generator/aws.ex`
- Create: `test/wagger/generator/aws_test.exs`

**AWS WAF specifics:**
- Output is JSON (AWS WAF v2 Web ACL structure)
- Uses `ByteMatchStatement` with `STARTS_WITH` for prefix, `EXACTLY` for exact without params, `RegexMatchStatement` for paths with params or regex type (NOT `CONTAINS` — this is the bug fix from the literate doc)
- Text transformations: `URL_DECODE` and `LOWERCASE` on every byte match
- Rate limits multiplied by 5 (AWS evaluates over 5-minute windows)
- Method enforcement groups routes by allowed method set to minimize rules

- [ ] **Step 1: Write the YANG model**

Create `yang/wagger-aws-waf.yang` modeling the AWS WAF v2 Web ACL structure:

```yang
module wagger-aws-waf {
  namespace "urn:wagger:aws-waf";
  prefix waw;

  organization "Wagger Project";
  description "Data model for AWS WAF v2 Web ACL configuration.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container web-acl {
    description "AWS WAF v2 Web ACL.";

    leaf name {
      type string;
      mandatory true;
    }

    leaf scope {
      type enumeration {
        enum "REGIONAL";
        enum "CLOUDFRONT";
      }
      mandatory true;
    }

    list rules {
      key "name";

      leaf name {
        type string;
        mandatory true;
      }

      leaf priority {
        type uint32;
        mandatory true;
      }

      leaf action {
        type enumeration {
          enum "Block";
          enum "Allow";
          enum "Count";
        }
        mandatory true;
      }

      leaf rule-type {
        type enumeration {
          enum "path-allowlist";
          enum "method-enforce";
          enum "rate-limit";
        }
        mandatory true;
      }

      list path-patterns {
        key "pattern";

        leaf pattern {
          type string;
          mandatory true;
        }

        leaf match-type {
          type enumeration {
            enum "EXACTLY";
            enum "STARTS_WITH";
            enum "REGEX";
          }
          mandatory true;
        }
      }

      leaf-list methods {
        type string;
      }

      leaf rate-limit-value {
        type uint32;
        description "Rate limit over 5-minute window.";
      }

      leaf metric-name {
        type string;
        mandatory true;
      }
    }
  }
}
```

Verify: `mix run -e 'source = File.read!("yang/wagger-aws-waf.yang"); {:ok, p} = ExYang.parse(source); {:ok, _} = ExYang.resolve(p, %{}); IO.puts("OK")'`

- [ ] **Step 2: Write failing tests**

```elixir
# test/wagger/generator/aws_test.exs
defmodule Wagger.Generator.AwsTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Aws

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp", scope: "REGIONAL"}

  describe "map_routes/2" do
    test "produces web-acl with name and scope" do
      instance = Aws.map_routes(@routes, @config)
      acl = instance["web-acl"]
      assert acl["name"] == "myapp-web-acl"
      assert acl["scope"] == "REGIONAL"
    end

    test "creates path-allowlist rule" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["web-acl"]["rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "path-allowlist"))
      assert allowlist != nil
      assert length(allowlist["path-patterns"]) == 4
    end

    test "uses REGEX for paths with params instead of CONTAINS" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["web-acl"]["rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "path-allowlist"))
      user_detail = Enum.find(allowlist["path-patterns"], &String.contains?(&1["pattern"], "users"))
      patterns = Enum.filter(allowlist["path-patterns"], &(&1["match-type"] == "REGEX"))
      assert length(patterns) > 0
    end

    test "multiplies rate limit by 5 for AWS window" do
      instance = Aws.map_routes(@routes, @config)
      rules = instance["web-acl"]["rules"]
      rate_rule = Enum.find(rules, &(&1["rule-type"] == "rate-limit"))
      assert rate_rule["rate-limit-value"] == 500
    end
  end

  describe "full pipeline" do
    test "generates valid AWS WAF JSON" do
      assert {:ok, output} = Generator.generate(Aws, @routes, @config)
      decoded = Jason.decode!(output)
      assert decoded["Name"] == "myapp-web-acl"
      assert decoded["Scope"] == "REGIONAL"
      assert is_list(decoded["Rules"])
    end

    test "includes text transformations" do
      {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "URL_DECODE"
      assert output =~ "LOWERCASE"
    end

    test "includes rate-based rule" do
      {:ok, output} = Generator.generate(Aws, @routes, @config)
      assert output =~ "RateBasedStatement"
      assert output =~ "500"
    end
  end
end
```

- [ ] **Step 3: Implement AWS generator**

Create `lib/wagger/generator/aws.ex` implementing `@behaviour Wagger.Generator`. Key implementation details:

- `map_routes/2`: Build path-allowlist rule with patterns for all routes. For exact paths without params use `EXACTLY`, for prefix use `STARTS_WITH`, for paths with params or regex use `REGEX` with `PathHelper.to_regex/1`. Group routes by method set for method-enforce rules. Create rate-limit rules for rate-limited routes (value * 5).
- `serialize/2`: Convert instance tree to AWS WAF v2 JSON structure with nested `ByteMatchStatement`/`RegexMatchStatement`, `OrStatement`/`NotStatement`/`AndStatement` wrappers, `TextTransformations`, `RateBasedStatement`. Use `Jason.encode!(data, pretty: true)`.

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/generator/aws_test.exs && mix test
```

- [ ] **Step 5: Commit**

```bash
git add yang/wagger-aws-waf.yang lib/wagger/generator/aws.ex test/wagger/generator/aws_test.exs
git commit -m "Add AWS WAF v2 generator with YANG-validated pipeline"
```

---

### Task 2: Cloudflare Generator

**Files:**
- Create: `yang/wagger-cloudflare.yang`
- Create: `lib/wagger/generator/cloudflare.ex`
- Create: `test/wagger/generator/cloudflare_test.exs`

**Cloudflare specifics:**
- Output is JSON (array of firewall rules)
- Uses expression language: `eq` for exact paths, `starts_with` for prefix, `matches` for regex/wildcard
- Path allowlist is a single rule: `not (expr1 or expr2 or ...)`
- Rate limiting uses `managed_challenge` action with `ratelimit` config
- Period is 60 seconds (our canonical per-minute maps directly)

- [ ] **Step 1: Write the YANG model**

Create `yang/wagger-cloudflare.yang`:

```yang
module wagger-cloudflare {
  namespace "urn:wagger:cloudflare";
  prefix wcf;

  organization "Wagger Project";
  description "Data model for Cloudflare firewall rules configuration.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container cloudflare-config {
    leaf config-name {
      type string;
      mandatory true;
    }

    list rules {
      key "description";

      leaf description {
        type string;
        mandatory true;
      }

      leaf expression {
        type string;
        mandatory true;
      }

      leaf action {
        type enumeration {
          enum "block";
          enum "managed_challenge";
          enum "allow";
          enum "log";
        }
        mandatory true;
      }

      leaf enabled {
        type boolean;
        mandatory true;
      }

      container ratelimit {
        leaf period {
          type uint32;
          mandatory true;
        }

        leaf requests-per-period {
          type uint32;
          mandatory true;
        }

        leaf mitigation-timeout {
          type uint32;
          mandatory true;
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write failing tests**

```elixir
# test/wagger/generator/cloudflare_test.exs
defmodule Wagger.Generator.CloudflareTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Cloudflare

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp"}

  describe "map_routes/2" do
    test "creates block rule for unknown paths" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block = Enum.find(rules, &(&1["action"] == "block"))
      assert block["expression"] =~ "not ("
    end

    test "uses eq for exact paths without params" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block = Enum.find(rules, &(&1["action"] == "block"))
      assert block["expression"] =~ ~s(http.request.uri.path eq "/health")
    end

    test "uses starts_with for prefix paths" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block = Enum.find(rules, &(&1["action"] == "block"))
      assert block["expression"] =~ "starts_with(http.request.uri.path"
    end

    test "uses matches for paths with params" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      block = Enum.find(rules, &(&1["action"] == "block"))
      assert block["expression"] =~ "matches"
    end

    test "creates rate limit rule with managed_challenge" do
      instance = Cloudflare.map_routes(@routes, @config)
      rules = instance["cloudflare-config"]["rules"]
      rate = Enum.find(rules, &(&1["action"] == "managed_challenge"))
      assert rate != nil
      assert rate["ratelimit"]["period"] == 60
      assert rate["ratelimit"]["requests-per-period"] == 100
    end
  end

  describe "full pipeline" do
    test "generates valid Cloudflare JSON" do
      assert {:ok, output} = Generator.generate(Cloudflare, @routes, @config)
      decoded = Jason.decode!(output)
      assert is_list(decoded)
      assert length(decoded) >= 2
    end
  end
end
```

- [ ] **Step 3: Implement Cloudflare generator**

Create `lib/wagger/generator/cloudflare.ex`. Key details:

- `map_routes/2`: Build path expressions per route using `to_cloudflare_expr/1` helper. For exact without params: `http.request.uri.path eq "/path"`. For prefix: `starts_with(http.request.uri.path, "/path")`. For params/regex: `http.request.uri.path matches "^regex$"`. Combine all into block rule: `not (expr1 or expr2 or ...)`. Add `managed_challenge` rules for rate-limited routes.
- `serialize/2`: Convert to JSON array of rule objects with `description`, `expression`, `action`, `enabled`, optional `ratelimit`. Use `Jason.encode!(rules, pretty: true)`.

- [ ] **Step 4: Run tests**

```bash
mix test test/wagger/generator/cloudflare_test.exs && mix test
```

- [ ] **Step 5: Commit**

```bash
git add yang/wagger-cloudflare.yang lib/wagger/generator/cloudflare.ex test/wagger/generator/cloudflare_test.exs
git commit -m "Add Cloudflare firewall rules generator with YANG validation"
```

---

### Task 3: Azure Front Door Generator

**Files:**
- Create: `yang/wagger-azure-fd.yang`
- Create: `lib/wagger/generator/azure.ex`
- Create: `test/wagger/generator/azure_test.exs`

**Azure specifics:**
- Output is JSON (Azure Front Door WAF policy)
- Uses `RegEx` operator for path matching with `negateCondition: true` for allowlist
- `matchValue` is an array of patterns (implicitly OR-ed)
- Transforms: `UrlDecode`, `Lowercase`
- Rate limits multiplied by 5 (5-minute window like AWS)
- Uses `RateLimitRule` type with `rateLimitDurationInMinutes: 5`

- [ ] **Step 1: Write the YANG model**

Create `yang/wagger-azure-fd.yang`:

```yang
module wagger-azure-fd {
  namespace "urn:wagger:azure-fd";
  prefix waz;

  organization "Wagger Project";
  description "Data model for Azure Front Door WAF policy.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container waf-policy {
    leaf policy-name {
      type string;
      mandatory true;
    }

    leaf mode {
      type enumeration {
        enum "Prevention";
        enum "Detection";
      }
      mandatory true;
    }

    list custom-rules {
      key "name";

      leaf name {
        type string;
        mandatory true;
      }

      leaf priority {
        type uint32;
        mandatory true;
      }

      leaf rule-type {
        type enumeration {
          enum "MatchRule";
          enum "RateLimitRule";
        }
        mandatory true;
      }

      leaf action {
        type enumeration {
          enum "Block";
          enum "Allow";
          enum "Log";
        }
        mandatory true;
      }

      leaf-list match-patterns {
        type string;
        description "Regex patterns for path matching.";
      }

      leaf negate-condition {
        type boolean;
      }

      leaf rate-limit-threshold {
        type uint32;
      }

      leaf rate-limit-duration {
        type uint32;
        description "Duration in minutes.";
      }
    }
  }
}
```

- [ ] **Step 2: Write failing tests**

```elixir
# test/wagger/generator/azure_test.exs
defmodule Wagger.Generator.AzureTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Azure

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp", mode: "Prevention"}

  describe "map_routes/2" do
    test "creates allowlist rule with negated condition" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["waf-policy"]["custom-rules"]
      allowlist = Enum.find(rules, &(&1["rule-type"] == "MatchRule"))
      assert allowlist["negate-condition"] == true
      assert length(allowlist["match-patterns"]) == 4
    end

    test "multiplies rate limit by 5" do
      instance = Azure.map_routes(@routes, @config)
      rules = instance["waf-policy"]["custom-rules"]
      rate_rule = Enum.find(rules, &(&1["rule-type"] == "RateLimitRule"))
      assert rate_rule["rate-limit-threshold"] == 500
      assert rate_rule["rate-limit-duration"] == 5
    end
  end

  describe "full pipeline" do
    test "generates valid Azure JSON" do
      assert {:ok, output} = Generator.generate(Azure, @routes, @config)
      decoded = Jason.decode!(output)
      assert decoded["properties"]["policySettings"]["mode"] == "Prevention"
      assert is_list(decoded["properties"]["customRules"]["rules"])
    end

    test "includes UrlDecode and Lowercase transforms" do
      {:ok, output} = Generator.generate(Azure, @routes, @config)
      assert output =~ "UrlDecode"
      assert output =~ "Lowercase"
    end
  end
end
```

- [ ] **Step 3: Implement Azure generator**

Create `lib/wagger/generator/azure.ex`. Serialize to Azure Front Door policy JSON with `properties.customRules.rules` array and `properties.policySettings`.

- [ ] **Step 4: Run tests and commit**

```bash
mix test test/wagger/generator/azure_test.exs && mix test
git add yang/wagger-azure-fd.yang lib/wagger/generator/azure.ex test/wagger/generator/azure_test.exs
git commit -m "Add Azure Front Door WAF policy generator with YANG validation"
```

---

### Task 4: GCP Cloud Armor Generator

**Files:**
- Create: `yang/wagger-gcp-armor.yang`
- Create: `lib/wagger/generator/gcp.ex`
- Create: `test/wagger/generator/gcp_test.exs`

**GCP specifics:**
- Output is JSON (Cloud Armor security policy)
- Uses CEL expressions for path matching: `request.path.matches('regex')`
- Rules have priorities (lower = higher priority)
- Default action is `allow` (the policy blocks non-matching, allows matching)
- Rate limiting uses `rate_based_ban` action with `rateLimitOptions`

- [ ] **Step 1: Write the YANG model**

Create `yang/wagger-gcp-armor.yang`:

```yang
module wagger-gcp-armor {
  namespace "urn:wagger:gcp-armor";
  prefix wga;

  organization "Wagger Project";
  description "Data model for Google Cloud Armor security policy.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container security-policy {
    leaf name {
      type string;
      mandatory true;
    }

    leaf description {
      type string;
    }

    list rules {
      key "priority";

      leaf priority {
        type uint32;
        mandatory true;
      }

      leaf description {
        type string;
      }

      leaf action {
        type enumeration {
          enum "allow";
          enum "deny(403)";
          enum "deny(404)";
          enum "rate_based_ban";
        }
        mandatory true;
      }

      leaf match-expression {
        type string;
        mandatory true;
        description "CEL expression for request matching.";
      }

      container rate-limit-options {
        leaf conform-action {
          type string;
          mandatory true;
        }

        leaf exceed-action {
          type string;
          mandatory true;
        }

        leaf rate-limit-threshold-count {
          type uint32;
          mandatory true;
        }

        leaf rate-limit-threshold-interval {
          type uint32;
          mandatory true;
          description "Interval in seconds.";
        }
      }
    }
  }
}
```

- [ ] **Step 2: Write failing tests**

```elixir
# test/wagger/generator/gcp_test.exs
defmodule Wagger.Generator.GcpTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Gcp

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp"}

  describe "map_routes/2" do
    test "creates deny rule for unknown paths" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["security-policy"]["rules"]
      deny = Enum.find(rules, &(&1["action"] == "deny(403)"))
      assert deny != nil
      assert deny["match-expression"] =~ "request.path"
    end

    test "creates rate_based_ban rule" do
      instance = Gcp.map_routes(@routes, @config)
      rules = instance["security-policy"]["rules"]
      rate = Enum.find(rules, &(&1["action"] == "rate_based_ban"))
      assert rate != nil
      assert rate["rate-limit-options"]["rate-limit-threshold-count"] == 100
    end
  end

  describe "full pipeline" do
    test "generates valid GCP JSON" do
      assert {:ok, output} = Generator.generate(Gcp, @routes, @config)
      decoded = Jason.decode!(output)
      assert decoded["name"] =~ "myapp"
      assert is_list(decoded["rules"])
    end

    test "uses CEL expressions" do
      {:ok, output} = Generator.generate(Gcp, @routes, @config)
      assert output =~ "request.path.matches"
    end
  end
end
```

- [ ] **Step 3: Implement GCP generator**

Create `lib/wagger/generator/gcp.ex`. CEL expressions: `!request.path.matches('regex1') && !request.path.matches('regex2')` for the deny rule. Rate limit rules use `request.path.matches('regex')` with `rate_based_ban` action.

- [ ] **Step 4: Run tests and commit**

```bash
mix test test/wagger/generator/gcp_test.exs && mix test
git add yang/wagger-gcp-armor.yang lib/wagger/generator/gcp.ex test/wagger/generator/gcp_test.exs
git commit -m "Add GCP Cloud Armor generator with YANG validation"
```

---

### Task 5: Caddy Generator

**Files:**
- Create: `yang/wagger-caddy.yang`
- Create: `lib/wagger/generator/caddy.ex`
- Create: `test/wagger/generator/caddy_test.exs`

**Caddy specifics:**
- Output is Caddyfile text (not JSON)
- Uses `@matcher` directives with `path` or `path_regexp` for matching
- `respond 403` for unmatched paths via a catch-all
- `method` matcher for method enforcement
- `rate_limit` directive for rate-limited routes
- `reverse_proxy` for upstream forwarding
- Structure: named matchers → route blocks → fallback

- [ ] **Step 1: Write the YANG model**

Create `yang/wagger-caddy.yang`:

```yang
module wagger-caddy {
  namespace "urn:wagger:caddy";
  prefix wcd;

  organization "Wagger Project";
  description "Data model for Caddy WAF-style configuration.";

  revision 2026-04-13 {
    description "Initial revision.";
  }

  container caddy-config {
    leaf config-name {
      type string;
      mandatory true;
    }

    leaf upstream {
      type string;
      mandatory true;
    }

    list routes {
      key "name";

      leaf name {
        type string;
        mandatory true;
      }

      leaf path-matcher {
        type string;
        mandatory true;
        description "Caddy path or path_regexp matcher.";
      }

      leaf matcher-type {
        type enumeration {
          enum "path";
          enum "path_regexp";
        }
        mandatory true;
      }

      leaf-list allowed-methods {
        type string;
      }

      leaf rate-limit-per-minute {
        type uint32;
      }
    }
  }
}
```

- [ ] **Step 2: Write failing tests**

```elixir
# test/wagger/generator/caddy_test.exs
defmodule Wagger.Generator.CaddyTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Caddy

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static files"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health check"}
  ]

  @config %{prefix: "myapp", upstream: "http://backend:8080"}

  describe "map_routes/2" do
    test "creates route entries for each route" do
      instance = Caddy.map_routes(@routes, @config)
      routes = instance["caddy-config"]["routes"]
      assert length(routes) == 4
    end

    test "uses path for exact routes without params" do
      instance = Caddy.map_routes(@routes, @config)
      routes = instance["caddy-config"]["routes"]
      health = Enum.find(routes, &(&1["name"] =~ "health"))
      assert health["matcher-type"] == "path"
    end

    test "uses path_regexp for routes with params" do
      instance = Caddy.map_routes(@routes, @config)
      routes = instance["caddy-config"]["routes"]
      user_detail = Enum.find(routes, &(&1["name"] =~ "users__"))
      assert user_detail["matcher-type"] == "path_regexp"
    end

    test "includes rate limit for rate-limited routes" do
      instance = Caddy.map_routes(@routes, @config)
      routes = instance["caddy-config"]["routes"]
      users = Enum.find(routes, &(&1["rate-limit-per-minute"] != nil))
      assert users["rate-limit-per-minute"] == 100
    end
  end

  describe "full pipeline" do
    test "generates valid Caddyfile" do
      assert {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "@"
      assert output =~ "reverse_proxy"
      assert output =~ "respond 403"
    end

    test "contains method restrictions" do
      {:ok, output} = Generator.generate(Caddy, @routes, @config)
      assert output =~ "method"
    end
  end
end
```

- [ ] **Step 3: Implement Caddy generator**

Create `lib/wagger/generator/caddy.ex`. Serialize to Caddyfile format:

```caddyfile
# WAF-style allowlist for myapp

@users {
  path /api/users
  method GET POST
}
@users_id {
  path_regexp ^/api/users/[^/]+$
  method GET PUT DELETE
}

route @users {
  rate_limit {per_minute 100}
  reverse_proxy http://backend:8080
}
route @users_id {
  reverse_proxy http://backend:8080
}

# Block everything else
respond 403
```

- [ ] **Step 4: Run tests and commit**

```bash
mix test test/wagger/generator/caddy_test.exs && mix test
git add yang/wagger-caddy.yang lib/wagger/generator/caddy.ex test/wagger/generator/caddy_test.exs
git commit -m "Add Caddy generator with YANG validation"
```
