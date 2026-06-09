# Apache httpd (mod_security2) Generator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `apache` WAF generator that emits Wagger's route-allowlist ModSecurity rules packaged as an Apache `mod_security2` include file.

**Architecture:** Extract the SecRule rule-building/rendering logic Coraza already has into a shared `Wagger.Generator.SecRule` module, refactor Coraza to use it (output unchanged), then build `Wagger.Generator.Apache` on top — same rule bodies, wrapped in an `<IfModule security2_module>` guard with audit-logging and working-dir directives.

**Tech Stack:** Elixir, Phoenix LiveView, ExYang (YANG schema validation), ExUnit.

---

## File Structure

- Create: `lib/wagger/generator/sec_rule.ex` — shared, behaviour-less rule core (build + render SecRules).
- Modify: `lib/wagger/generator/coraza.ex` — delegate rule build/render to `SecRule`; output byte-identical.
- Create: `yang/wagger-apache.yang` — `apache-config` schema (Coraza rule shape + packaging leaves).
- Create: `lib/wagger/generator/apache.ex` — `Wagger.Generator` behaviour, mod_security2 packaging.
- Create: `test/wagger/generator/apache_test.exs` — unit + full-pipeline tests.
- Modify: `lib/wagger_web/live/app_detail_live.ex` — register `apache`.
- Modify: `lib/wagger_web/live/hub_detail_live.ex` — register `apache`.
- Modify: `lib/wagger_web/live/dashboard_live.ex` — register `apache`.
- Modify: `lib/wagger_web/controllers/generate_controller.ex` — register `apache`.
- Modify: `README.md` — generator count + list.

The `coraza_test.exs` suite is the regression guard for the Task 1 extraction — it must stay green with no edits.

---

## Task 1: Extract shared `SecRule` core, refactor Coraza

**Files:**
- Create: `lib/wagger/generator/sec_rule.ex`
- Modify: `lib/wagger/generator/coraza.ex`
- Guard (do not edit): `test/wagger/generator/coraza_test.exs`

- [ ] **Step 1: Run the Coraza suite to capture the green baseline**

Run: `mix test test/wagger/generator/coraza_test.exs`
Expected: PASS (all Coraza tests green) — this is the byte-behaviour we must preserve.

- [ ] **Step 2: Create the shared `SecRule` module**

Create `lib/wagger/generator/sec_rule.ex`:

```elixir
defmodule Wagger.Generator.SecRule do
  @moduledoc """
  Shared ModSecurity SecRule construction and rendering, used by both the
  Coraza and Apache generators. Pure functions — no `Wagger.Generator`
  behaviour. The rule bodies produced here are byte-for-byte identical
  between Coraza (standalone engine) and Apache (`mod_security2`); only the
  surrounding packaging differs per provider.
  """

  @default_start_rule_id 100_001
  @catch_all_offset 90_000

  @doc "Default first rule ID when config supplies none."
  def default_start_rule_id, do: @default_start_rule_id

  @doc "Offset added to the start rule ID to derive the catch-all rule ID."
  def catch_all_offset, do: @catch_all_offset

  @doc """
  Builds the per-route rule list plus the start/catch-all IDs from routes and
  config. Returns `%{rules: [...], start_id: integer, catch_all_id: integer}`.
  Each rule is a string-keyed map: `id`, `path-pattern`, `methods`, optional
  `description`, optional `rate-limit-comment`.
  """
  def build_rules(routes, config) do
    start_id = parse_int(config, "start_rule_id", @default_start_rule_id)

    rules =
      routes
      |> Enum.with_index()
      |> Enum.map(fn {route, idx} -> build_rule(route, start_id + idx) end)

    %{rules: rules, start_id: start_id, catch_all_id: start_id + @catch_all_offset}
  end

  defp build_rule(route, id) do
    r = normalize(route)
    pattern = Wagger.Generator.PathHelper.to_regex(r)

    base = %{
      "id" => id,
      "path-pattern" => pattern,
      "methods" => r.methods
    }

    base =
      if r.description do
        Map.put(base, "description", r.description)
      else
        base
      end

    if r.rate_limit do
      Map.put(base, "rate-limit-comment", "#{r.rate_limit} req/min (enforce at proxy layer)")
    else
      base
    end
  end

  @doc "Renders all per-route SecRule blocks, newline-joined."
  def render_rules(rules) do
    Enum.map_join(rules, "\n", &render_rule/1)
  end

  @doc "Renders a single chained allow SecRule block."
  def render_rule(rule) do
    id = rule["id"]
    pattern = rule["path-pattern"]
    methods = rule["methods"]
    description = Map.get(rule, "description")
    rate_comment = Map.get(rule, "rate-limit-comment")

    methods_str = Enum.join(methods, " ")

    comment =
      if description do
        "# #{methods_str} #{original_path_from_pattern(pattern)} — #{description}"
      else
        "# #{methods_str} #{original_path_from_pattern(pattern)}"
      end

    rate_line =
      if rate_comment do
        "\n# Rate limit: #{rate_comment}"
      else
        ""
      end

    """
    #{comment}#{rate_line}
    SecRule REQUEST_URI "@rx #{pattern}" "id:#{id},phase:1,chain,allow"
      SecRule REQUEST_METHOD "@pm #{methods_str}" "t:none"
    """
  end

  @doc "Renders the final catch-all deny block for undeclared paths."
  def render_catch_all(id, phase, status) do
    """
    # Deny all undeclared paths
    SecRule REQUEST_URI "@rx .*" "id:#{id},phase:#{phase},deny,status:#{status},msg:'No matching route'"
    """
  end

  @doc false
  def normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      rate_limit: route[:rate_limit] || route["rate_limit"],
      description: route[:description] || route["description"]
    }
  end

  @doc false
  def original_path_from_pattern(pattern) do
    pattern
    |> String.replace_prefix("^", "")
    |> String.replace_suffix("$", "")
    |> String.replace_suffix(".*", "/")
  end

  @doc false
  def iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc false
  def parse_int(config, key, default) do
    val = config[String.to_atom(key)] || config[key]

    case val do
      nil -> default
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
    end
  end
end
```

- [ ] **Step 3: Refactor Coraza to delegate to `SecRule`**

Replace the body of `lib/wagger/generator/coraza.ex` with this (module attributes and the `@default_start_rule_id`/`@catch_all_offset` constants are now removed in favour of `SecRule`; private helpers that moved are deleted):

```elixir
defmodule Wagger.Generator.Coraza do
  @moduledoc """
  Coraza/ModSecurity WAF config generator implementing the `Wagger.Generator` behaviour.

  Produces a standalone SecRule `.conf` file with:
  - `SecRuleEngine` and `SecDefaultAction` engine directives
  - Per-route `SecRule` entries with chained method enforcement
  - Rate-limit annotations as comments (not natively supported)
  - A catch-all deny rule for undeclared paths

  Rule construction and rendering are delegated to `Wagger.Generator.SecRule`,
  shared with the Apache `mod_security2` generator.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.SecRule

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-coraza.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    %{rules: rules, start_id: start_id, catch_all_id: catch_all_id} =
      SecRule.build_rules(routes, config)

    rule_engine = config[:rule_engine] || config["rule_engine"] || "On"
    config_name = config[:prefix] || config["prefix"] || "coraza"

    %{
      "coraza-config" => %{
        "config-name" => config_name,
        "generated-at" => SecRule.iso8601_now(),
        "rule-engine" => rule_engine,
        "default-action-phase" => 1,
        "default-action-status" => 403,
        "start-rule-id" => start_id,
        "rules" => rules,
        "catch-all-rule-id" => catch_all_id
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["coraza-config"]
    config_name = cfg["config-name"]
    generated_at = cfg["generated-at"]
    rule_engine = cfg["rule-engine"]
    phase = cfg["default-action-phase"]
    status = cfg["default-action-status"]
    rules = cfg["rules"]
    catch_all_id = cfg["catch-all-rule-id"]

    header = """
    # Generated by Wagger for app: #{config_name}
    # Timestamp: #{generated_at}

    SecRuleEngine #{rule_engine}
    SecRequestBodyAccess On
    SecDefaultAction "phase:#{phase},log,auditlog,deny,status:#{status}"
    """

    rule_blocks = SecRule.render_rules(rules)
    catch_all = SecRule.render_catch_all(catch_all_id, phase, status)

    (header <> "\n" <> rule_blocks <> "\n" <> catch_all)
    |> String.trim_trailing()
  end
end
```

- [ ] **Step 4: Run the Coraza suite — must still be green**

Run: `mix test test/wagger/generator/coraza_test.exs`
Expected: PASS (identical to Step 1 — the extraction preserved behaviour).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/sec_rule.ex lib/wagger/generator/coraza.ex
git commit -m "refactor(generator): extract shared SecRule core from Coraza"
```

---

## Task 2: Apache YANG schema

**Files:**
- Create: `yang/wagger-apache.yang`

- [ ] **Step 1: Write the schema**

Create `yang/wagger-apache.yang`:

```text
module wagger-apache {
  namespace "urn:wagger:apache";
  prefix wap;

  organization "Wagger Project";
  description "Data model for Apache mod_security2 SecRule WAF configuration.";

  revision 2026-06-09 {
    description "Initial revision.";
  }

  container apache-config {
    description "Top-level Apache mod_security2 SecRule WAF configuration.";

    leaf config-name {
      type string;
      mandatory true;
      description "Identifier for this configuration.";
    }

    leaf generated-at {
      type string;
      description "ISO 8601 timestamp of generation.";
    }

    leaf rule-engine {
      type enumeration {
        enum "On";
        enum "Off";
        enum "DetectionOnly";
      }
      mandatory true;
      description "SecRuleEngine mode.";
    }

    leaf default-action-phase {
      type uint8;
      mandatory true;
      description "Default phase for SecDefaultAction.";
    }

    leaf default-action-status {
      type uint16;
      mandatory true;
      description "Default deny status code.";
    }

    leaf start-rule-id {
      type uint32;
      mandatory true;
      description "First rule ID in the generated sequence.";
    }

    leaf audit-log-path {
      type string;
      description "Path for SecAuditLog.";
    }

    leaf tmp-dir {
      type string;
      description "Path for SecTmpDir.";
    }

    leaf data-dir {
      type string;
      description "Path for SecDataDir.";
    }

    list rules {
      key "id";
      description "Per-route SecRule entries.";

      leaf id {
        type uint32;
        mandatory true;
        description "Unique SecRule ID.";
      }

      leaf description {
        type string;
        description "Human-readable rule description.";
      }

      leaf path-pattern {
        type string;
        mandatory true;
        description "Regex pattern for REQUEST_URI matching.";
      }

      leaf-list methods {
        type string;
        description "Allowed HTTP methods for this path.";
      }

      leaf rate-limit-comment {
        type string;
        description "Rate limit annotation for operator reference.";
      }
    }

    leaf catch-all-rule-id {
      type uint32;
      mandatory true;
      description "Rule ID for the final catch-all deny rule.";
    }
  }
}
```

- [ ] **Step 2: Sanity-check the YANG parses/resolves**

Run:

```bash
mix run -e 'src = File.read!("yang/wagger-apache.yang"); {:ok, p} = ExYang.parse(src); {:ok, _} = ExYang.resolve(p, %{}); IO.puts("apache yang OK")'
```

Expected: prints `apache yang OK` (no parse/resolve error).

- [ ] **Step 3: Commit**

```bash
git add yang/wagger-apache.yang
git commit -m "feat(generator): add wagger-apache YANG schema"
```

---

## Task 3: Apache generator module

**Files:**
- Create: `lib/wagger/generator/apache.ex`
- Test: `test/wagger/generator/apache_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/wagger/generator/apache_test.exs`:

```elixir
defmodule Wagger.Generator.ApacheTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Wagger.Generator
  alias Wagger.Generator.Apache

  @routes [
    %{path: "/api/users", methods: ["GET", "POST"], path_type: "exact", rate_limit: 100, description: "Users"},
    %{path: "/api/users/{id}", methods: ["GET", "PUT", "DELETE"], path_type: "exact", rate_limit: nil, description: "User detail"},
    %{path: "/static/", methods: ["GET"], path_type: "prefix", rate_limit: nil, description: "Static"},
    %{path: "/health", methods: ["GET"], path_type: "exact", rate_limit: nil, description: "Health"}
  ]

  @config %{prefix: "myapp"}

  describe "map_routes/2" do
    test "produces apache-config with config-name matching prefix" do
      instance = Apache.map_routes(@routes, @config)
      assert instance["apache-config"]["config-name"] == "myapp"
    end

    test "rule IDs increment sequentially from default start" do
      instance = Apache.map_routes(@routes, @config)
      ids = instance["apache-config"]["rules"] |> Enum.map(& &1["id"])
      assert ids == [100_001, 100_002, 100_003, 100_004]
    end

    test "catch-all rule ID is start + 90000" do
      instance = Apache.map_routes(@routes, @config)
      assert instance["apache-config"]["catch-all-rule-id"] == 190_001
    end

    test "packaging leaves default when config omits them" do
      instance = Apache.map_routes(@routes, @config)
      cfg = instance["apache-config"]
      assert cfg["audit-log-path"] == "/var/log/apache2/modsec_audit.log"
      assert cfg["tmp-dir"] == "/tmp"
      assert cfg["data-dir"] == "/var/cache/modsecurity"
    end

    test "packaging leaves honour overrides" do
      config = Map.merge(@config, %{audit_log_path: "/var/log/ms.log", tmp_dir: "/srv/tmp", data_dir: "/srv/data"})
      cfg = Apache.map_routes(@routes, config)["apache-config"]
      assert cfg["audit-log-path"] == "/var/log/ms.log"
      assert cfg["tmp-dir"] == "/srv/tmp"
      assert cfg["data-dir"] == "/srv/data"
    end
  end

  describe "generate/3 full pipeline" do
    test "wraps everything in an IfModule security2_module guard" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "<IfModule security2_module>"
      assert output =~ "</IfModule>"
      # the guard opens before any SecRule and closes after the catch-all
      open = :binary.match(output, "<IfModule security2_module>") |> elem(0)
      close = :binary.match(output, "</IfModule>") |> elem(0)
      first_rule = :binary.match(output, "SecRule") |> elem(0)
      assert open < first_rule
      assert first_rule < close
    end

    test "emits engine directives" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "SecRuleEngine On"
      assert output =~ "SecRequestBodyAccess On"
      assert output =~ ~s(SecDefaultAction "phase:1,log,auditlog,deny,status:403")
    end

    test "emits audit-logging directives" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "SecAuditEngine RelevantOnly"
      assert output =~ "SecAuditLog /var/log/apache2/modsec_audit.log"
      assert output =~ "SecAuditLogParts ABIJDEFHZ"
    end

    test "emits working-dir directives" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "SecTmpDir /tmp"
      assert output =~ "SecDataDir /var/cache/modsecurity"
    end

    test "each route produces a chained SecRule with method enforcement" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ ~s(SecRule REQUEST_URI "@rx ^/api/users$" "id:100001,phase:1,chain,allow")
      assert output =~ ~s(SecRule REQUEST_METHOD "@pm GET POST" "t:none")
    end

    test "catch-all deny rule present" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "# Deny all undeclared paths"
      assert output =~ ~s(id:190001,phase:1,deny,status:403,msg:'No matching route')
    end

    test "rate-limit comments appear for rate-limited routes" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "# Rate limit: 100 req/min"
    end

    test "header includes app name" do
      assert {:ok, output} = Generator.generate(Apache, @routes, @config)
      assert output =~ "# Generated by Wagger for app: myapp"
    end

    test "DetectionOnly mode produces correct engine directive" do
      config = Map.put(@config, :rule_engine, "DetectionOnly")
      assert {:ok, output} = Generator.generate(Apache, @routes, config)
      assert output =~ "SecRuleEngine DetectionOnly"
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/wagger/generator/apache_test.exs`
Expected: FAIL — `Wagger.Generator.Apache` is undefined.

- [ ] **Step 3: Write the Apache generator**

Create `lib/wagger/generator/apache.ex`:

```elixir
defmodule Wagger.Generator.Apache do
  @moduledoc """
  Apache `mod_security2` WAF config generator implementing the
  `Wagger.Generator` behaviour.

  Produces a self-contained `.conf` include file: the same per-route ModSecurity
  SecRules the Coraza generator emits (built via `Wagger.Generator.SecRule`),
  wrapped in an `<IfModule security2_module>` guard with engine, audit-logging,
  and working-dir directives. Meant to be pulled in via `Include` (or dropped
  inside an existing vhost).
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.SecRule

  @default_audit_log "/var/log/apache2/modsec_audit.log"
  @default_tmp_dir "/tmp"
  @default_data_dir "/var/cache/modsecurity"

  @impl true
  def yang_module do
    Path.join(:code.priv_dir(:wagger), "../yang/wagger-apache.yang")
    |> File.read!()
  end

  @impl true
  def map_routes(routes, config) do
    %{rules: rules, start_id: start_id, catch_all_id: catch_all_id} =
      SecRule.build_rules(routes, config)

    rule_engine = config[:rule_engine] || config["rule_engine"] || "On"
    config_name = config[:prefix] || config["prefix"] || "apache"

    %{
      "apache-config" => %{
        "config-name" => config_name,
        "generated-at" => SecRule.iso8601_now(),
        "rule-engine" => rule_engine,
        "default-action-phase" => 1,
        "default-action-status" => 403,
        "start-rule-id" => start_id,
        "audit-log-path" => config[:audit_log_path] || config["audit_log_path"] || @default_audit_log,
        "tmp-dir" => config[:tmp_dir] || config["tmp_dir"] || @default_tmp_dir,
        "data-dir" => config[:data_dir] || config["data_dir"] || @default_data_dir,
        "rules" => rules,
        "catch-all-rule-id" => catch_all_id
      }
    }
  end

  @impl true
  def serialize(instance, _schema) do
    cfg = instance["apache-config"]
    config_name = cfg["config-name"]
    generated_at = cfg["generated-at"]
    rule_engine = cfg["rule-engine"]
    phase = cfg["default-action-phase"]
    status = cfg["default-action-status"]
    rules = cfg["rules"]
    catch_all_id = cfg["catch-all-rule-id"]

    engine = """
    SecRuleEngine #{rule_engine}
    SecRequestBodyAccess On
    SecDefaultAction "phase:#{phase},log,auditlog,deny,status:#{status}"

    # --- audit logging ---
    SecAuditEngine RelevantOnly
    SecAuditLog #{cfg["audit-log-path"]}
    SecAuditLogParts ABIJDEFHZ

    # --- working dirs ---
    SecTmpDir #{cfg["tmp-dir"]}
    SecDataDir #{cfg["data-dir"]}

    # --- route allowlist ---
    """

    rule_blocks = SecRule.render_rules(rules)
    catch_all = SecRule.render_catch_all(catch_all_id, phase, status)

    inner =
      (engine <> "\n" <> rule_blocks <> "\n" <> catch_all)
      |> String.trim_trailing()

    """
    # Generated by Wagger for app: #{config_name}
    # Timestamp: #{generated_at}

    <IfModule security2_module>
    #{indent(inner, 2)}
    </IfModule>
    """
    |> String.trim_trailing()
  end

  defp indent(text, spaces) do
    pad = String.duplicate(" ", spaces)

    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/wagger/generator/apache_test.exs`
Expected: PASS (all Apache tests green).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/apache.ex test/wagger/generator/apache_test.exs
git commit -m "feat(generator): add Apache mod_security2 generator"
```

---

## Task 4: Register the `apache` provider in the UI and API

**Files:**
- Modify: `lib/wagger_web/live/app_detail_live.ex`
- Modify: `lib/wagger_web/live/hub_detail_live.ex`
- Modify: `lib/wagger_web/live/dashboard_live.ex`
- Modify: `lib/wagger_web/controllers/generate_controller.ex`

- [ ] **Step 1: Register in `app_detail_live.ex`**

Change the `@providers` list (line ~18):

```elixir
  @providers ~w(apache aws azure caddy cloudflare coraza gcp nginx zap)
```

Change the Ingress bucket (line ~25):

```elixir
    {"Ingress Configs", ~w(apache aws azure caddy cloudflare coraza gcp nginx)},
```

In `@provider_modules`, add after the `"coraza" => Wagger.Generator.Coraza,` line:

```elixir
    "apache" => Wagger.Generator.Apache,
```

In `@provider_config_fields`, add an `apache` entry alongside the `coraza` entry:

```elixir
    "apache" => [
      {"prefix", "Name prefix", :text},
      {"start_rule_id", "Starting rule ID (default 100001)", :text},
      {"audit_log_path", "Audit log path (default /var/log/apache2/modsec_audit.log)", :text},
      {"tmp_dir", "SecTmpDir (default /tmp)", :text},
      {"data_dir", "SecDataDir (default /var/cache/modsecurity)", :text}
    ],
```

- [ ] **Step 2: Register in `hub_detail_live.ex`**

Change the `@providers` list (line ~32):

```elixir
  @providers ~w(apache aws azure caddy cloudflare coraza gcp nginx zap)
```

Change the Ingress bucket (line ~36):

```elixir
    {"Ingress Configs", ~w(apache aws azure caddy cloudflare coraza gcp nginx)},
```

In `@provider_modules`, add after the `"coraza" => Wagger.Generator.Coraza,` line:

```elixir
    "apache" => Wagger.Generator.Apache,
```

In `@provider_config_fields`, add the same `apache` entry as Step 1:

```elixir
    "apache" => [
      {"prefix", "Name prefix", :text},
      {"start_rule_id", "Starting rule ID (default 100001)", :text},
      {"audit_log_path", "Audit log path (default /var/log/apache2/modsec_audit.log)", :text},
      {"tmp_dir", "SecTmpDir (default /tmp)", :text},
      {"data_dir", "SecDataDir (default /var/cache/modsecurity)", :text}
    ],
```

- [ ] **Step 3: Register in `dashboard_live.ex`**

Change the `@providers` list (line ~16):

```elixir
  @providers ~w(apache aws azure caddy cloudflare coraza gcp nginx zap)
```

- [ ] **Step 4: Register in `generate_controller.ex`**

In `@providers` (the module map, line ~24), add after the `"coraza" => Wagger.Generator.Coraza,` line:

```elixir
    "apache" => Wagger.Generator.Apache,
```

- [ ] **Step 5: Verify it compiles cleanly and the full suite passes**

Run: `mix compile --warnings-as-errors && mix test`
Expected: PASS — full suite green (previously 648; now higher with the new Apache tests), no compiler warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/live/app_detail_live.ex lib/wagger_web/live/hub_detail_live.ex lib/wagger_web/live/dashboard_live.ex lib/wagger_web/controllers/generate_controller.ex
git commit -m "feat(ui): register Apache mod_security2 provider"
```

---

## Task 5: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Update the generator count and list**

In `README.md`, find the line beginning "Eight generators ship today" and change it to nine, inserting Apache. New text:

```text
Nine generators ship today -- AWS WAF, Cloudflare, Azure Front Door, GCP Cloud Armor, Nginx, Caddy, Apache (mod_security2), Coraza/ModSecurity, and an OWASP ZAP test plan generator that verifies your deployed config is actually blocking what it should.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: note Apache mod_security2 generator"
```

---

## Self-Review Notes

- **Spec coverage:** shared `SecRule` core (Task 1) ✓, bare include file output shape (Task 3) ✓, `<IfModule>` guard + audit + working-dirs, no LoadModule (Task 3 serialize + tests) ✓, `wagger-apache.yang` self-contained with packaging leaves (Task 2) ✓, registration across all four files incl. Ingress group (Task 4) ✓, config fields with defaults (Task 4) ✓, Coraza byte-identical guarded by unedited `coraza_test.exs` (Task 1 Steps 1/4) ✓, README (Task 5) ✓.
- **Rate limiting** stays as comment annotation via the shared `SecRule.build_rules/2` — no native enforcement, matching spec non-goals.
- **Type consistency:** `SecRule.build_rules/2` returns `%{rules:, start_id:, catch_all_id:}` and is destructured identically in both Coraza and Apache `map_routes/2`. `render_rules/1`, `render_catch_all/3`, `iso8601_now/0` signatures match call sites.
