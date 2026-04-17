# Wagger MCP Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the first slice of MCP support in wagger — a generator that emits `my-app-mcp.yang` source text from a flat capability map, importing a canonical `mcp.yang` shipped with wagger.

**Architecture:** One hand-authored canonical `yang/mcp.yang` (revision `2025-06-18`). One new provider module `Wagger.Generator.Mcp` alongside existing WAF providers. One pure `Wagger.Generator.Mcp.Builder` module that turns capability maps into `ExYang.Model.Module{}` structs. `Wagger.Generator` behaviour gains one optional callback `map_capabilities/2`; `generate/3` dispatches on its presence so WAF providers stay untouched. `ExYang.Encoder.Encoder` turns the struct into YANG source text; the emitted text is round-tripped through `ExYang.parse/1` + `ExYang.resolve/2` for validation.

**Tech Stack:** Elixir, Phoenix, ExYang (parser + encoder + resolver), Comn.Errors (error registry), ExUnit.

**Design doc:** `docs/superpowers/specs/2026-04-17-wagger-mcp-provider-design.md`

---

## File Structure

**New:**
- `yang/mcp.yang` — canonical base module, hand-authored.
- `lib/wagger/generator/mcp.ex` — provider module.
- `lib/wagger/generator/mcp/builder.ex` — pure functions: capability map → `ExYang.Model.*` structs, validation.
- `test/wagger/generator/mcp/canonical_test.exs` — asserts canonical module parses and resolves.
- `test/wagger/generator/mcp/builder_test.exs` — unit tests for Builder.
- `test/wagger/generator/mcp_test.exs` — full-pipeline integration tests.
- `test/support/fixtures/mcp/minimal.yang` — golden output fixture.

**Modified:**
- `lib/wagger/errors.ex` — register three new error IDs.
- `lib/wagger/generator/generator.ex` — add optional callback and dispatch.

---

## Task 1: Register new error IDs

**Files:**
- Modify: `lib/wagger/errors.ex:11-27`

- [ ] **Step 1: Add the three new error registrations**

Add these lines after line 27 (after `serialization_failed`), inside the `# -- Generator pipeline --` block:

```elixir
  register_error "wagger.generator/invalid_capabilities", :validation,
    message: "Capability map is malformed"

  register_error "wagger.generator/mcp_roundtrip_failed", :internal,
    message: "Generated MCP YANG failed round-trip validation"

  register_error "wagger.generator/canonical_mcp_invalid", :internal,
    message: "Canonical mcp.yang failed to parse or resolve"
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/wagger/errors.ex
git commit -m "Register MCP generator error IDs"
```

---

## Task 2: Canonical mcp.yang + smoke test (write test first)

**Files:**
- Create: `yang/mcp.yang`
- Create: `test/wagger/generator/mcp/canonical_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/wagger/generator/mcp/canonical_test.exs`:

```elixir
defmodule Wagger.Generator.Mcp.CanonicalTest do
  use ExUnit.Case, async: true

  @canonical_path Path.join(File.cwd!(), "yang/mcp.yang")

  setup_all do
    source = File.read!(@canonical_path)
    {:ok, source: source}
  end

  test "canonical mcp.yang parses successfully", %{source: source} do
    assert {:ok, _parsed} = ExYang.parse(source)
  end

  test "canonical mcp.yang resolves against empty registry", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert {:ok, _resolved} = ExYang.resolve(parsed, %{})
  end

  test "module name is mcp", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert parsed.name == "mcp"
  end

  test "revision date is 2025-06-18", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert Enum.any?(parsed.revisions, fn r -> r.date == "2025-06-18" end)
  end

  test "declares core groupings", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    grouping_names = Enum.map(parsed.groupings, & &1.name)
    for name <- ~w(tool-definition resource-definition prompt-definition capabilities server-info) do
      assert name in grouping_names, "missing grouping: #{name}"
    end
  end

  test "declares lifecycle RPCs", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    rpc_names = Enum.map(parsed.rpcs, & &1.name)
    for name <- ~w(initialize ping tools-list tools-call resources-list resources-read prompts-list prompts-get) do
      assert name in rpc_names, "missing rpc: #{name}"
    end
  end

  test "declares notifications", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    notif_names = Enum.map(parsed.notifications, & &1.name)
    for name <- ~w(tools-list-changed resources-updated prompts-list-changed) do
      assert name in notif_names, "missing notification: #{name}"
    end
  end

  test "declares transport identities", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    identity_names = Enum.map(parsed.identities, & &1.name)
    for name <- ~w(transport stdio streamable-http sse) do
      assert name in identity_names, "missing identity: #{name}"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/canonical_test.exs`
Expected: FAIL — `yang/mcp.yang` does not exist.

- [ ] **Step 3: Write canonical mcp.yang**

Create `yang/mcp.yang` with this exact content:

```yang
module mcp {
  yang-version 1.1;
  namespace "urn:ietf:params:xml:ns:yang:mcp";
  prefix mcp;

  organization "Wagger";
  contact "https://github.com/smithisms/wagger";
  description
    "YANG model for the Model Context Protocol (MCP).

     Models the protocol envelope, capability negotiation, lifecycle RPCs,
     notifications, and transport identities. Dynamic per-tool JSON Schema
     is represented as anydata; concrete typed refinement is expected in
     per-application modules that import this one.";
  reference "https://modelcontextprotocol.io/specification/2025-06-18";

  revision 2025-06-18 {
    description "Aligned with MCP specification revision 2025-06-18.";
  }

  // -- Transport identities --

  identity transport {
    description "Base identity for MCP transports.";
  }

  identity stdio {
    base transport;
    description "stdio transport (MCP §Transports).";
  }

  identity streamable-http {
    base transport;
    description "Streamable HTTP transport.";
  }

  identity sse {
    base transport;
    description "Server-Sent Events transport (legacy).";
  }

  // -- Core groupings --

  grouping tool-definition {
    description "Shape of a single MCP tool declaration.";
    leaf name {
      type string;
      mandatory true;
      description "Unique tool name within the server.";
    }
    leaf title {
      type string;
      description "Human-readable tool title.";
    }
    leaf description {
      type string;
      description "Human-readable tool description.";
    }
    anydata input-schema {
      description "JSON Schema for tool input (draft 2020-12).";
    }
    anydata output-schema {
      description "JSON Schema for tool output (draft 2020-12).";
    }
  }

  grouping resource-definition {
    description "Shape of a single MCP resource declaration.";
    leaf uri-template {
      type string;
      mandatory true;
      description "RFC 6570 URI template for the resource.";
    }
    leaf name {
      type string;
      description "Human-readable resource name.";
    }
    leaf title {
      type string;
      description "Human-readable resource title.";
    }
    leaf description {
      type string;
      description "Human-readable resource description.";
    }
    leaf mime-type {
      type string;
      description "MIME type of the resource content.";
    }
  }

  grouping prompt-definition {
    description "Shape of a single MCP prompt declaration.";
    leaf name {
      type string;
      mandatory true;
      description "Unique prompt name within the server.";
    }
    leaf title {
      type string;
      description "Human-readable prompt title.";
    }
    leaf description {
      type string;
      description "Human-readable prompt description.";
    }
    list arguments {
      key "name";
      description "Declared prompt arguments.";
      leaf name {
        type string;
        mandatory true;
      }
      leaf description {
        type string;
      }
      leaf required {
        type boolean;
        default "false";
      }
    }
  }

  grouping capabilities {
    description "Server capability negotiation flags (MCP §Capabilities).";
    container tools {
      leaf list-changed { type boolean; default "false"; }
    }
    container resources {
      leaf list-changed { type boolean; default "false"; }
      leaf subscribe { type boolean; default "false"; }
    }
    container prompts {
      leaf list-changed { type boolean; default "false"; }
    }
    container logging {
      presence "server supports logging";
    }
  }

  grouping server-info {
    description "Server identification returned from initialize.";
    leaf name { type string; mandatory true; }
    leaf version { type string; mandatory true; }
  }

  // -- Lifecycle RPCs --

  rpc initialize {
    description "Client-to-server initialize handshake.";
    input {
      leaf protocol-version { type string; mandatory true; }
      container client-info {
        leaf name { type string; }
        leaf version { type string; }
      }
      anydata client-capabilities;
    }
    output {
      leaf protocol-version { type string; mandatory true; }
      container server-info {
        uses server-info;
      }
      container capabilities {
        uses capabilities;
      }
    }
  }

  rpc ping {
    description "Liveness probe.";
  }

  rpc tools-list {
    description "List available tools (JSON-RPC method tools/list).";
    output {
      list tools {
        key "name";
        uses tool-definition;
      }
    }
  }

  rpc tools-call {
    description "Invoke a tool (JSON-RPC method tools/call).";
    input {
      leaf name { type string; mandatory true; }
      anydata arguments;
    }
    output {
      anydata content;
      leaf is-error { type boolean; default "false"; }
    }
  }

  rpc resources-list {
    description "List available resources (JSON-RPC method resources/list).";
    output {
      list resources {
        key "uri-template";
        uses resource-definition;
      }
    }
  }

  rpc resources-read {
    description "Read a resource (JSON-RPC method resources/read).";
    input {
      leaf uri { type string; mandatory true; }
    }
    output {
      anydata contents;
    }
  }

  rpc prompts-list {
    description "List available prompts (JSON-RPC method prompts/list).";
    output {
      list prompts {
        key "name";
        uses prompt-definition;
      }
    }
  }

  rpc prompts-get {
    description "Render a prompt (JSON-RPC method prompts/get).";
    input {
      leaf name { type string; mandatory true; }
      anydata arguments;
    }
    output {
      leaf description { type string; }
      anydata messages;
    }
  }

  // -- Notifications --

  notification tools-list-changed {
    description "Server announces the tool list changed.";
  }

  notification resources-updated {
    description "Server announces a resource was updated.";
    leaf uri { type string; mandatory true; }
  }

  notification prompts-list-changed {
    description "Server announces the prompt list changed.";
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/canonical_test.exs`
Expected: PASS (8 tests).

**If any test fails:** the likely culprit is ex_yang parser rejecting specific YANG constructs. Read the diagnostic, consult `deps/ex_yang/lib/ex_yang/parser/grammar.ex` for supported statements, and adjust the canonical module. Do not weaken the tests — adjust the YANG.

- [ ] **Step 5: Commit**

```bash
git add yang/mcp.yang test/wagger/generator/mcp/canonical_test.exs
git commit -m "Add canonical mcp.yang (MCP 2025-06-18) with smoke tests"
```

---

## Task 3: Extend Generator behaviour with `map_capabilities/2` dispatch

**Files:**
- Modify: `lib/wagger/generator/generator.ex`

- [ ] **Step 1: Add the optional callback declaration**

After the existing `@callback serialize/2` declaration (line 27), insert:

```elixir
  @doc """
  Alternative entry point for capability-shaped providers (e.g. MCP).

  Returns an `ExYang.Model.Module{}` struct representing the generated YANG
  module. The orchestrator encodes it and round-trip-validates.
  """
  @callback map_capabilities(capabilities :: map(), config :: map()) ::
              {:ok, ExYang.Model.Module.t()} | {:error, term()}
  @optional_callbacks map_capabilities: 2, map_routes: 2, serialize: 2
```

- [ ] **Step 2: Add dispatch in `generate/3`**

Replace the body of `generate/3` (lines 34-63) with:

```elixir
  def generate(provider_module, input, config) do
    if function_exported?(provider_module, :map_capabilities, 2) do
      generate_capabilities(provider_module, input, config)
    else
      generate_routes(provider_module, input, config)
    end
  end

  defp generate_routes(provider_module, routes, config) do
    yang_source = provider_module.yang_module()

    with {:ok, parsed} <- ExYang.parse(yang_source),
         {:ok, resolved} <- ExYang.resolve(parsed, %{}),
         instance = provider_module.map_routes(routes, config),
         :ok <- Validator.validate(instance, resolved) do
      output = provider_module.serialize(instance, resolved)
      {:ok, output}
    else
      {:error, reasons} when is_list(reasons) ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/validation_failed",
           message: Enum.join(reasons, "; "),
           field: "instance"
         )}

      {:error, reason} when is_binary(reason) ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_parse_failed",
           message: reason
         )}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_resolve_failed",
           message: inspect(reason)
         )}
    end
  end

  defp generate_capabilities(provider_module, capabilities, config) do
    canonical_source = provider_module.yang_module()

    with {:ok, canonical_parsed} <- parse_canonical(canonical_source),
         {:ok, canonical_resolved} <- resolve_canonical(canonical_parsed),
         {:ok, module_struct} <- provider_module.map_capabilities(capabilities, config),
         yang_text = ExYang.Encoder.Encoder.encode(module_struct),
         {:ok, reparsed} <- reparse(yang_text),
         {:ok, _} <- reresolve(reparsed, canonical_resolved) do
      {:ok, yang_text}
    end
  end

  defp parse_canonical(source) do
    case ExYang.parse(source) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/canonical_mcp_invalid",
           message: "parse failed: #{inspect(reason)}"
         )}
    end
  end

  defp resolve_canonical(parsed) do
    case ExYang.resolve(parsed, %{}) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/canonical_mcp_invalid",
           message: "resolve failed: #{inspect(reason)}"
         )}
    end
  end

  defp reparse(yang_text) do
    case ExYang.parse(yang_text) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/mcp_roundtrip_failed",
           message: "reparse failed: #{inspect(reason)}"
         )}
    end
  end

  defp reresolve(parsed, canonical_resolved) do
    registry = %{"mcp" => canonical_resolved}

    case ExYang.resolve(parsed, registry) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/mcp_roundtrip_failed",
           message: "reresolve failed: #{inspect(reason)}"
         )}
    end
  end
```

**Note:** The registry shape passed to `ExYang.resolve/2` (`%{"mcp" => canonical_resolved}`) is assumed. If the actual signature differs, inspect `deps/ex_yang/lib/ex_yang/ex_yang.ex` and adjust. Do not guess — read the source.

- [ ] **Step 2a: Verify the registry shape**

Run: `grep -n "def resolve" deps/ex_yang/lib/ex_yang/ex_yang.ex deps/ex_yang/lib/ex_yang/resolver/*.ex`

Read the resolve function signature and documentation. If the expected registry shape is not `%{module_name => resolved_module}`, adjust the `registry = ...` line above. Common alternatives: a list of resolved modules, or a struct wrapper.

- [ ] **Step 3: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no errors.

- [ ] **Step 4: Verify existing WAF tests still pass**

Run: `mix test test/wagger/generator/`
Expected: all existing generator tests pass (the route pipeline must not regress).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/generator.ex
git commit -m "Add map_capabilities/2 callback and dispatch to Wagger.Generator"
```

---

## Task 4: Builder — `validate/1`

**Files:**
- Create: `lib/wagger/generator/mcp/builder.ex`
- Create: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/wagger/generator/mcp/builder_test.exs`:

```elixir
defmodule Wagger.Generator.Mcp.BuilderTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator.Mcp.Builder

  describe "validate/1" do
    test "accepts minimal valid capability map" do
      caps = %{app_name: "my-app", tools: [], resources: [], prompts: []}
      assert :ok = Builder.validate(caps)
    end

    test "rejects missing app_name" do
      assert {:error, {:missing, "app_name"}} =
               Builder.validate(%{tools: [], resources: [], prompts: []})
    end

    test "rejects invalid app_name (not a valid YANG identifier)" do
      assert {:error, {:invalid_identifier, "app_name", "9bad"}} =
               Builder.validate(%{app_name: "9bad", tools: [], resources: [], prompts: []})

      assert {:error, {:invalid_identifier, "app_name", "bad space"}} =
               Builder.validate(%{app_name: "bad space", tools: [], resources: [], prompts: []})
    end

    test "rejects tool without name" do
      caps = %{app_name: "my-app", tools: [%{description: "x"}], resources: [], prompts: []}
      assert {:error, {:missing, "tools[0].name"}} = Builder.validate(caps)
    end

    test "rejects duplicate tool names" do
      caps = %{
        app_name: "my-app",
        tools: [%{name: "search"}, %{name: "search"}],
        resources: [],
        prompts: []
      }
      assert {:error, {:duplicate, "tools", "search"}} = Builder.validate(caps)
    end

    test "rejects resource without uri_template" do
      caps = %{
        app_name: "my-app",
        tools: [],
        resources: [%{name: "r"}],
        prompts: []
      }
      assert {:error, {:missing, "resources[0].uri_template"}} = Builder.validate(caps)
    end

    test "rejects prompt without name" do
      caps = %{
        app_name: "my-app",
        tools: [],
        resources: [],
        prompts: [%{description: "x"}]
      }
      assert {:error, {:missing, "prompts[0].name"}} = Builder.validate(caps)
    end

    test "defaults missing primitive lists to empty" do
      assert :ok = Builder.validate(%{app_name: "my-app"})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — module `Wagger.Generator.Mcp.Builder` does not exist.

- [ ] **Step 3: Implement Builder.validate/1**

Create `lib/wagger/generator/mcp/builder.ex`:

```elixir
defmodule Wagger.Generator.Mcp.Builder do
  @moduledoc """
  Pure functions that turn a capability map into `ExYang.Model.*` structs.

  Validation and struct construction only. No I/O, no encoding, no parsing.
  """

  @yang_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_\-\.]*\z/

  @doc """
  Validates a capability map. Returns `:ok` or a structured error tuple.

  Errors take the form:
  - `{:missing, path}` — required field absent
  - `{:invalid_identifier, path, value}` — field is not a valid YANG identifier
  - `{:duplicate, collection, name}` — duplicate primitive name
  """
  def validate(%{} = caps) do
    with :ok <- require_key(caps, :app_name),
         :ok <- valid_identifier(caps, :app_name),
         :ok <- validate_tools(Map.get(caps, :tools, [])),
         :ok <- validate_resources(Map.get(caps, :resources, [])),
         :ok <- validate_prompts(Map.get(caps, :prompts, [])) do
      :ok
    end
  end

  defp require_key(caps, key) do
    if Map.has_key?(caps, key), do: :ok, else: {:error, {:missing, to_string(key)}}
  end

  defp valid_identifier(caps, key) do
    value = Map.fetch!(caps, key)
    if Regex.match?(@yang_identifier, value) do
      :ok
    else
      {:error, {:invalid_identifier, to_string(key), value}}
    end
  end

  defp validate_tools(tools) do
    with :ok <- require_field_in_list(tools, :name, "tools"),
         :ok <- no_duplicates(tools, :name, "tools") do
      :ok
    end
  end

  defp validate_resources(resources) do
    with :ok <- require_field_in_list(resources, :uri_template, "resources"),
         :ok <- no_duplicates(resources, :uri_template, "resources") do
      :ok
    end
  end

  defp validate_prompts(prompts) do
    with :ok <- require_field_in_list(prompts, :name, "prompts"),
         :ok <- no_duplicates(prompts, :name, "prompts") do
      :ok
    end
  end

  defp require_field_in_list(list, field, collection) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, idx}, :ok ->
      if Map.has_key?(entry, field) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing, "#{collection}[#{idx}].#{field}"}}}
      end
    end)
  end

  defp no_duplicates(list, field, collection) do
    names = Enum.map(list, &Map.fetch!(&1, field))
    dup = names -- Enum.uniq(names)

    case dup do
      [] -> :ok
      [name | _] -> {:error, {:duplicate, collection, name}}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.validate/1 for MCP capability maps"
```

---

## Task 5: Builder — `derive_identity/1`

**Files:**
- Modify: `lib/wagger/generator/mcp/builder.ex`
- Modify: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `test/wagger/generator/mcp/builder_test.exs` (before the final `end`):

```elixir
  describe "derive_identity/1" do
    test "derives module_name, namespace, and prefix from app_name" do
      assert %{
               module_name: "my-app-mcp",
               namespace: "urn:wagger:my-app:mcp",
               prefix: "my-app"
             } = Builder.derive_identity(%{app_name: "my-app"})
    end

    test "handles single-word app names" do
      assert %{
               module_name: "acme-mcp",
               namespace: "urn:wagger:acme:mcp",
               prefix: "acme"
             } = Builder.derive_identity(%{app_name: "acme"})
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — `derive_identity/1` undefined.

- [ ] **Step 3: Implement derive_identity/1**

Append inside `defmodule Wagger.Generator.Mcp.Builder` (before the final `end`):

```elixir
  @doc """
  Derives YANG module identity from the `app_name` per wagger convention.

  - `module_name = "\#{app_name}-mcp"`
  - `namespace = "urn:wagger:\#{app_name}:mcp"`
  - `prefix = app_name`
  """
  def derive_identity(%{app_name: app_name}) do
    %{
      module_name: "#{app_name}-mcp",
      namespace: "urn:wagger:#{app_name}:mcp",
      prefix: app_name
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.derive_identity/1"
```

---

## Task 6: Builder — `build_tools_container/1`

**Files:**
- Modify: `lib/wagger/generator/mcp/builder.ex`
- Modify: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Verify ExYang struct shapes**

Read the following files to confirm struct field names before writing tests:

- `deps/ex_yang/lib/ex_yang/model/container.ex`
- `deps/ex_yang/lib/ex_yang/model/list.ex`
- `deps/ex_yang/lib/ex_yang/model/uses.ex`
- `deps/ex_yang/lib/ex_yang/model/leaf.ex`

Note the exact `defstruct` keys. The code below assumes: `%ExYang.Model.Container{name, description, body}`, `%ExYang.Model.List{name, key, body}`, `%ExYang.Model.Uses{name}`, `%ExYang.Model.Leaf{name, type, default, description}`. If any differ, adjust the test and implementation before proceeding.

- [ ] **Step 2: Write the failing test**

Append to `builder_test.exs`:

```elixir
  describe "build_tools_container/1" do
    test "empty tools list produces empty container" do
      container = Builder.build_tools_container([])

      assert %ExYang.Model.Container{name: "tools"} = container
      assert container.body == []
    end

    test "single tool produces a list entry with uses mcp:tool-definition" do
      tools = [
        %{
          name: "search",
          description: "Full-text search",
          input_schema: %{"type" => "object"},
          output_schema: %{"type" => "object"}
        }
      ]

      container = Builder.build_tools_container(tools)

      assert %ExYang.Model.Container{name: "tools"} = container
      assert [list_entry] = container.body
      assert %ExYang.Model.List{name: "tool", key: "name"} = list_entry

      # The list body should contain a name leaf and a uses statement.
      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Leaf{name: "name"} -> true
               _ -> false
             end)

      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Uses{name: "mcp:tool-definition"} -> true
               _ -> false
             end)
    end

    test "multiple tools produce multiple list entries" do
      tools = [%{name: "a"}, %{name: "b"}, %{name: "c"}]
      container = Builder.build_tools_container(tools)
      assert length(container.body) == 3
    end
  end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — `build_tools_container/1` undefined.

- [ ] **Step 4: Implement build_tools_container/1**

Append to `builder.ex`:

```elixir
  @doc """
  Builds the `tools` container projecting declared tools through
  `mcp:tool-definition` groupings.
  """
  def build_tools_container(tools) when is_list(tools) do
    %ExYang.Model.Container{
      name: "tools",
      description: "Declared MCP tools.",
      body:
        Enum.map(tools, fn tool ->
          %ExYang.Model.List{
            name: "tool",
            key: "name",
            body: [
              %ExYang.Model.Leaf{
                name: "name",
                type: %ExYang.Model.Type{name: "string"},
                default: Map.fetch!(tool, :name)
              },
              %ExYang.Model.Uses{name: "mcp:tool-definition"}
            ]
          }
        end)
    }
  end
```

**Note:** `%ExYang.Model.Type{name: "string"}` is assumed. If the Type struct uses a different field name (e.g. `:type_name`, or is a plain string), adjust. Read `deps/ex_yang/lib/ex_yang/model/type.ex` before writing this step.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (13 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.build_tools_container/1"
```

---

## Task 7: Builder — `build_resources_container/1`

**Files:**
- Modify: `lib/wagger/generator/mcp/builder.ex`
- Modify: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `builder_test.exs`:

```elixir
  describe "build_resources_container/1" do
    test "empty resources list produces empty container" do
      container = Builder.build_resources_container([])
      assert %ExYang.Model.Container{name: "resources", body: []} = container
    end

    test "single resource produces a list entry with uses mcp:resource-definition" do
      resources = [
        %{uri_template: "file://{path}", name: "file", mime_type: "text/plain"}
      ]

      container = Builder.build_resources_container(resources)
      assert [list_entry] = container.body
      assert %ExYang.Model.List{name: "resource", key: "uri-template"} = list_entry

      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Uses{name: "mcp:resource-definition"} -> true
               _ -> false
             end)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — `build_resources_container/1` undefined.

- [ ] **Step 3: Implement build_resources_container/1**

Append to `builder.ex`:

```elixir
  @doc """
  Builds the `resources` container projecting declared resources through
  `mcp:resource-definition` groupings.
  """
  def build_resources_container(resources) when is_list(resources) do
    %ExYang.Model.Container{
      name: "resources",
      description: "Declared MCP resources.",
      body:
        Enum.map(resources, fn resource ->
          %ExYang.Model.List{
            name: "resource",
            key: "uri-template",
            body: [
              %ExYang.Model.Leaf{
                name: "uri-template",
                type: %ExYang.Model.Type{name: "string"},
                default: Map.fetch!(resource, :uri_template)
              },
              %ExYang.Model.Uses{name: "mcp:resource-definition"}
            ]
          }
        end)
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (15 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.build_resources_container/1"
```

---

## Task 8: Builder — `build_prompts_container/1`

**Files:**
- Modify: `lib/wagger/generator/mcp/builder.ex`
- Modify: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `builder_test.exs`:

```elixir
  describe "build_prompts_container/1" do
    test "empty prompts list produces empty container" do
      container = Builder.build_prompts_container([])
      assert %ExYang.Model.Container{name: "prompts", body: []} = container
    end

    test "single prompt produces a list entry with uses mcp:prompt-definition" do
      prompts = [
        %{name: "summarize", arguments: [%{name: "length", required: true}]}
      ]

      container = Builder.build_prompts_container(prompts)
      assert [list_entry] = container.body
      assert %ExYang.Model.List{name: "prompt", key: "name"} = list_entry

      assert Enum.any?(list_entry.body, fn
               %ExYang.Model.Uses{name: "mcp:prompt-definition"} -> true
               _ -> false
             end)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — `build_prompts_container/1` undefined.

- [ ] **Step 3: Implement build_prompts_container/1**

Append to `builder.ex`:

```elixir
  @doc """
  Builds the `prompts` container projecting declared prompts through
  `mcp:prompt-definition` groupings.
  """
  def build_prompts_container(prompts) when is_list(prompts) do
    %ExYang.Model.Container{
      name: "prompts",
      description: "Declared MCP prompts.",
      body:
        Enum.map(prompts, fn prompt ->
          %ExYang.Model.List{
            name: "prompt",
            key: "name",
            body: [
              %ExYang.Model.Leaf{
                name: "name",
                type: %ExYang.Model.Type{name: "string"},
                default: Map.fetch!(prompt, :name)
              },
              %ExYang.Model.Uses{name: "mcp:prompt-definition"}
            ]
          }
        end)
    }
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (17 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.build_prompts_container/1"
```

---

## Task 9: Builder — `build_module/2` full assembly

**Files:**
- Modify: `lib/wagger/generator/mcp/builder.ex`
- Modify: `test/wagger/generator/mcp/builder_test.exs`

- [ ] **Step 1: Write the failing test**

Append to `builder_test.exs`:

```elixir
  describe "build_module/2" do
    test "returns error on invalid capabilities" do
      assert {:error, {:missing, "app_name"}} = Builder.build_module(%{}, %{})
    end

    test "returns an ExYang.Model.Module struct with derived identity" do
      caps = %{app_name: "my-app"}
      assert {:ok, module} = Builder.build_module(caps, %{})
      assert %ExYang.Model.Module{} = module
      assert module.name == "my-app-mcp"
      assert module.namespace == "urn:wagger:my-app:mcp"
      assert module.prefix == "my-app"
    end

    test "imports mcp with revision 2025-06-18" do
      caps = %{app_name: "my-app"}
      {:ok, module} = Builder.build_module(caps, %{})
      assert [%ExYang.Model.Import{module: "mcp", prefix: "mcp", revision_date: "2025-06-18"}] =
               module.imports
    end

    test "includes a revision entry" do
      caps = %{app_name: "my-app"}
      {:ok, module} = Builder.build_module(caps, %{})
      assert [%ExYang.Model.Revision{} = rev] = module.revisions
      assert rev.description =~ "wagger"
    end

    test "body contains the three primitive containers" do
      caps = %{
        app_name: "my-app",
        tools: [%{name: "search"}],
        resources: [%{uri_template: "x://{y}"}],
        prompts: [%{name: "p"}]
      }

      {:ok, module} = Builder.build_module(caps, %{})
      names = Enum.map(module.body, & &1.name)
      assert "tools" in names
      assert "resources" in names
      assert "prompts" in names
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: FAIL — `build_module/2` undefined.

- [ ] **Step 3: Verify Import and Revision struct shapes**

Read before coding:
- `deps/ex_yang/lib/ex_yang/model/import.ex`
- `deps/ex_yang/lib/ex_yang/model/revision.ex`

Confirm the field names `module`, `prefix`, `revision_date` (Import) and `date`, `description` (Revision). Adjust the test and implementation if they differ.

- [ ] **Step 4: Implement build_module/2**

Append to `builder.ex`:

```elixir
  @canonical_revision "2025-06-18"

  @doc """
  Validates the capability map and assembles the full
  `ExYang.Model.Module{}` struct for the per-app MCP module.

  Returns `{:ok, module}` or `{:error, reason}` from `validate/1`.
  """
  def build_module(capabilities, _config) do
    with :ok <- validate(capabilities) do
      identity = derive_identity(capabilities)

      {:ok,
       %ExYang.Model.Module{
         name: identity.module_name,
         namespace: identity.namespace,
         prefix: identity.prefix,
         yang_version: "1.1",
         imports: [
           %ExYang.Model.Import{
             module: "mcp",
             prefix: "mcp",
             revision_date: @canonical_revision
           }
         ],
         revisions: [
           %ExYang.Model.Revision{
             date: Date.utc_today() |> Date.to_iso8601(),
             description: "Generated by wagger."
           }
         ],
         body: [
           build_tools_container(Map.get(capabilities, :tools, [])),
           build_resources_container(Map.get(capabilities, :resources, [])),
           build_prompts_container(Map.get(capabilities, :prompts, []))
         ]
       }}
    end
  end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/wagger/generator/mcp/builder_test.exs`
Expected: PASS (22 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/wagger/generator/mcp/builder.ex test/wagger/generator/mcp/builder_test.exs
git commit -m "Add Builder.build_module/2 assembling the full MCP module"
```

---

## Task 10: Provider module `Wagger.Generator.Mcp`

**Files:**
- Create: `lib/wagger/generator/mcp.ex`

- [ ] **Step 1: Write the provider**

Create `lib/wagger/generator/mcp.ex`:

```elixir
defmodule Wagger.Generator.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) generator implementing the `Wagger.Generator`
  behaviour via the capability pipeline.

  Emits a per-application YANG module (`my-app-mcp.yang`) that imports the
  canonical `mcp.yang` shipped with wagger. Input is a flat capability map
  describing tools, resources, and prompts; output is YANG source text.

  See `docs/superpowers/specs/2026-04-17-wagger-mcp-provider-design.md`.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.Mcp.Builder

  @external_resource Path.join([__DIR__, "..", "..", "..", "yang", "mcp.yang"])
  @canonical_source File.read!(@external_resource)

  @impl true
  def yang_module, do: @canonical_source

  @impl true
  def map_capabilities(capabilities, config) do
    case Builder.build_module(capabilities, config) do
      {:ok, module} ->
        {:ok, module}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/invalid_capabilities",
           message: format_reason(reason),
           field: field_for_reason(reason)
         )}
    end
  end

  defp format_reason({:missing, field}), do: "Required field missing: #{field}"
  defp format_reason({:invalid_identifier, field, value}),
    do: "Field #{field} is not a valid YANG identifier: #{inspect(value)}"
  defp format_reason({:duplicate, collection, name}),
    do: "Duplicate entry in #{collection}: #{inspect(name)}"

  defp field_for_reason({:missing, field}), do: field
  defp field_for_reason({:invalid_identifier, field, _}), do: field
  defp field_for_reason({:duplicate, collection, _}), do: collection
end
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no errors. The `@external_resource` + `File.read!/1` at compile time bakes `yang/mcp.yang` into the compiled bytecode and adds a recompile dependency.

- [ ] **Step 3: Commit**

```bash
git add lib/wagger/generator/mcp.ex
git commit -m "Add Wagger.Generator.Mcp provider module"
```

---

## Task 11: Integration test + golden fixture

**Files:**
- Create: `test/wagger/generator/mcp_test.exs`
- Create: `test/support/fixtures/mcp/minimal.yang` (generated in the test, checked in)

- [ ] **Step 1: Write the failing integration test**

Create `test/wagger/generator/mcp_test.exs`:

```elixir
defmodule Wagger.Generator.McpTest do
  use ExUnit.Case, async: true

  @fixture_path "test/support/fixtures/mcp/minimal.yang"

  describe "Wagger.Generator.generate/3 with Mcp provider" do
    test "emits YANG source for a minimal capability map" do
      caps = %{app_name: "demo", tools: [], resources: [], prompts: []}

      assert {:ok, source} = Wagger.Generator.generate(Wagger.Generator.Mcp, caps, %{})
      assert is_binary(source)
      assert source =~ "module demo-mcp"
      assert source =~ ~s(namespace "urn:wagger:demo:mcp")
      assert source =~ "import mcp"
      assert source =~ "2025-06-18"
    end

    test "emitted source round-trips through ExYang.parse/1" do
      caps = %{app_name: "demo", tools: [%{name: "search"}], resources: [], prompts: []}
      {:ok, source} = Wagger.Generator.generate(Wagger.Generator.Mcp, caps, %{})
      assert {:ok, _parsed} = ExYang.parse(source)
    end

    test "validation errors are surfaced as ErrorStruct" do
      assert {:error, err} =
               Wagger.Generator.generate(Wagger.Generator.Mcp, %{}, %{})

      assert err.code == "wagger.generator/invalid_capabilities"
    end

    test "matches golden fixture for minimal input" do
      caps = %{app_name: "demo", tools: [], resources: [], prompts: []}
      {:ok, source} = Wagger.Generator.generate(Wagger.Generator.Mcp, caps, %{})

      # Normalize the revision date (which floats to Date.utc_today/0) for
      # the golden comparison.
      normalized = Regex.replace(~r/revision \d{4}-\d{2}-\d{2}/, source, "revision YYYY-MM-DD")

      expected = File.read!(@fixture_path)
      assert normalized == expected
    end
  end
end
```

- [ ] **Step 2: Run test to verify most pass, golden fails**

Run: `mix test test/wagger/generator/mcp_test.exs`
Expected: first three tests PASS; fourth FAIL — fixture file does not exist.

- [ ] **Step 3: Generate the fixture**

Run this one-liner from the project root to produce the current output for the minimal case, normalized:

```bash
mkdir -p test/support/fixtures/mcp
mix run -e '
  caps = %{app_name: "demo", tools: [], resources: [], prompts: []}
  {:ok, source} = Wagger.Generator.generate(Wagger.Generator.Mcp, caps, %{})
  normalized = Regex.replace(~r/revision \d{4}-\d{2}-\d{2}/, source, "revision YYYY-MM-DD")
  File.write!("test/support/fixtures/mcp/minimal.yang", normalized)
'
```

- [ ] **Step 4: Inspect the fixture**

Run: `cat test/support/fixtures/mcp/minimal.yang`

Confirm the output looks like a sensible YANG module: `module demo-mcp { ... }`, imports `mcp` with the right revision, contains three empty containers (`tools`, `resources`, `prompts`), has a `revision YYYY-MM-DD` line. If anything looks malformed, stop and debug before committing — the fixture is the contract.

- [ ] **Step 5: Run the full integration test**

Run: `mix test test/wagger/generator/mcp_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the entire generator test suite**

Run: `mix test test/wagger/generator/`
Expected: all tests pass — WAF providers unaffected, MCP tests all green.

- [ ] **Step 7: Commit**

```bash
git add test/wagger/generator/mcp_test.exs test/support/fixtures/mcp/minimal.yang
git commit -m "Add MCP generator integration test with golden fixture"
```

---

## Task 12: Precommit + final verification

**Files:** none (verification only)

- [ ] **Step 1: Run precommit**

Run: `mix precommit`
Expected: all checks pass (format, compile, tests).

- [ ] **Step 2: Verify full test suite**

Run: `mix test`
Expected: all tests pass, nothing regressed.

- [ ] **Step 3: Verify no uncommitted changes**

Run: `git status`
Expected: working tree clean, on main, ahead of origin by 11 commits (Tasks 1–11 each produced one commit).

- [ ] **Step 4: Review the commit series**

Run: `git log --oneline main -11`

Confirm each commit message corresponds to a task. If any task was forgotten or merged incorrectly, stop and report.
