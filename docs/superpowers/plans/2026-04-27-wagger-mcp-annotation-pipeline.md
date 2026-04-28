# Wagger MCP Annotation Pipeline + UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `yang/wagger-mcp-extensions.yang` (eight MCP annotation extensions), a `Wagger.Generator.Mcp.Deriver` that walks an annotated YANG module producing a capability map + report, a `generate_from_yang/2` provider entry, and a standalone `/mcp` LiveView with paste/upload + report rendering + download.

**Architecture:** Default-on policy: every `rpc`, every keyed `list`, every top-level `container` is exposed unless `wagger-mcp:exclude`. Annotations override auto-derivation (kebab→snake tool names, `<list>://{<key>}` URI templates). Pipeline: source → `ExYang.parse` → `ExYang.resolve` (against extensions module registry) → `Deriver.derive` → existing `Builder.build_module` → `ExYang.Encoder.Encoder.encode`. UI is a standalone LiveView at `/mcp`; download served by a `Phoenix.Token`-signed controller endpoint. Stateless.

**Tech Stack:** Elixir, Phoenix LiveView, ExYang (parser/encoder/resolver), Comn.Errors, Phoenix.Token, ExUnit, Phoenix.LiveViewTest.

**Design doc:** `docs/superpowers/specs/2026-04-27-wagger-mcp-annotation-pipeline-design.md`

**Prerequisite quirk (Task 1):** ex_yang's `Rpc` struct has no `body` field, so prefixed extension uses (`wagger-mcp:tool-name`, etc.) inside an `rpc` block are silently dropped during parsing. Container/List/Notification already preserve them via `body: build_body(subs)`. We patch `Rpc` to capture extensions in a new `extensions: []` field.

**Soft scope notes:**
- **File upload deferred.** Spec mentions "paste/upload" in the UI. This plan implements paste-only via textarea. File upload via `live_file_input` is a follow-up (the textarea covers the same workflow; users paste from their editor). Add it as a small follow-on plan if real friction emerges.
- **Tool flag emission deferred.** `wagger-mcp:dangerous` and `wagger-mcp:read-only` are derived and surfaced in the derivation report, but NOT emitted as fields in the generated `my-app-mcp.yang`. Doing so requires extending canonical `mcp.yang`'s `tool-definition` grouping with optional flag leaves and updating `Builder.build_tools_container/1`. Separate spec.

---

## File Structure

**New:**
- `yang/wagger-mcp-extensions.yang` — extension definitions (8 statements), revision `2026-04-27`.
- `lib/wagger/generator/mcp/deriver.ex` — pure: annotated module → capability map + derivation report.
- `lib/wagger_web/live/mcp_generator_live.ex` + `lib/wagger_web/live/mcp_generator_live.html.heex` — `/mcp` page.
- `lib/wagger_web/controllers/mcp_download_controller.ex` — token-signed download endpoint.
- `test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`
- `test/wagger/generator/mcp/deriver_test.exs`
- `test/wagger_web/live/mcp_generator_live_test.exs`
- `test/wagger_web/controllers/mcp_download_controller_test.exs`
- `test/support/fixtures/mcp/annotated_service.yang` — fixture input.
- `test/support/fixtures/mcp/annotated_service-mcp.yang` — golden output.

**Modified:**
- `lib/wagger/generator/mcp.ex` — adds `generate_from_yang/2`.
- `lib/wagger/errors.ex` — registers `wagger.generator/derivation_failed`.
- `lib/wagger_web/router.ex` — adds `live "/mcp"` and `get "/mcp/download/:token"`.
- `mix.exs`, `mix.lock` — bump ex_yang fork branch SHA after Task 1.

**Modified externally (in user's `imsmith/ex_yang` fork):**
- `lib/ex_yang/model/schema.ex` — `Rpc` struct gains `extensions: []`.
- `lib/ex_yang/transform/builder.ex` — `do_build(:rpc, ...)` captures `is_tuple(kw)` subs into `extensions`.

---

## Task 1: ex_yang fork — preserve extensions on Rpc

**Repo:** `imsmith/ex_yang` (separate clone).
**Branch:** new branch `fix/rpc-extensions` based on current `fix/grammar-atom-table-timing` (already pinned by wagger).

- [ ] **Step 1: Clone or update local ex_yang fork**

```bash
cd /tmp && rm -rf ex_yang && git clone https://github.com/imsmith/ex_yang.git
cd ex_yang
git checkout fix/grammar-atom-table-timing
git checkout -b fix/rpc-extensions
```

- [ ] **Step 2: Write the failing test**

Create `/tmp/ex_yang/test/extensions_on_rpc_test.exs`:

```elixir
defmodule ExYangExtensionsOnRpcTest do
  use ExUnit.Case, async: true

  test "rpc preserves prefixed extension uses in :extensions field" do
    src = """
    module t {
      yang-version 1.1;
      namespace "urn:t";
      prefix t;
      revision 2026-04-27 { description "x"; }
      rpc create-note {
        wagger-mcp:tool-name "create_note";
        wagger-mcp:dangerous;
        description "Save a note.";
      }
    }
    """

    assert {:ok, parsed} = ExYang.parse(src)
    [rpc] = parsed.rpcs
    assert length(rpc.extensions) == 2

    Enum.find(rpc.extensions, fn e -> e.keyword == {"wagger-mcp", "tool-name"} end)
    |> tap(fn e ->
      refute is_nil(e), "tool-name extension missing"
      assert e.argument == "create_note"
    end)

    Enum.find(rpc.extensions, fn e -> e.keyword == {"wagger-mcp", "dangerous"} end)
    |> tap(fn e -> refute is_nil(e), "dangerous extension missing" end)
  end
end
```

- [ ] **Step 3: Run test to verify FAIL**

`cd /tmp/ex_yang && mix test test/extensions_on_rpc_test.exs`
Expected: FAIL — `KeyError` on `:extensions`.

- [ ] **Step 4: Add `extensions: []` to Rpc struct**

In `lib/ex_yang/model/schema.ex`, find `defmodule ExYang.Model.Rpc do` and add `extensions: []` to its `defstruct` keyword list (alongside `meta:`, `comments:`, etc.).

- [ ] **Step 5: Update Rpc builder**

In `lib/ex_yang/transform/builder.ex`, find `defp do_build(:rpc, name, subs, meta)` and add `extensions:` field by filtering tuple-keyword subs:

```elixir
  defp do_build(:rpc, name, subs, meta) do
    %Rpc{
      name: name,
      input: build_one(subs, :input),
      output: build_one(subs, :output),
      status: take_status(subs),
      description: take_one(subs, :description),
      reference: take_one(subs, :reference),
      typedefs: build_all(subs, :typedef),
      groupings: build_all(subs, :grouping),
      if_features: take_all_args(subs, :"if-feature"),
      extensions:
        subs
        |> Elixir.Enum.filter(fn {kw, _, _, _} -> is_tuple(kw) end)
        |> Elixir.Enum.map(fn {kw, arg, sub_subs, m} ->
          build_extension_use(kw, arg, sub_subs, m)
        end),
      meta: meta,
      comments: comments_from(meta)
    }
  end
```

- [ ] **Step 6: Run test to verify PASS**

`mix test test/extensions_on_rpc_test.exs` — expect PASS.

- [ ] **Step 7: Run full ex_yang test suite to confirm no regression**

`mix test` — expect all existing tests pass plus the new one.

- [ ] **Step 8: Commit and push**

```bash
git add lib/ex_yang/model/schema.ex lib/ex_yang/transform/builder.ex test/extensions_on_rpc_test.exs
git commit -m "Preserve prefixed extension uses on Rpc in :extensions field"
git push -u origin fix/rpc-extensions
```

- [ ] **Step 9: Capture commit SHA for Task 2**

`git rev-parse HEAD` — record the SHA. Task 2 needs it.

---

## Task 2: Bump wagger ex_yang dependency

**Files:** Modify `mix.exs`, regenerate `mix.lock`.
**Working directory:** `/home/imsmith/github/wagger` (main worktree, on a new feature branch).

- [ ] **Step 1: Create feature branch**

```bash
cd /home/imsmith/github/wagger
git checkout -b feat/wagger-mcp-annotation
```

- [ ] **Step 2: Update mix.exs to point at new branch**

In `mix.exs`, find the `ex_yang` dep line (around line 73) and change `branch: "fix/grammar-atom-table-timing"` to `branch: "fix/rpc-extensions"`. Update the comment block above it accordingly:

```elixir
      # Pinned to fork-branch combining atom-table timing fix and rpc extensions
      # capture (RFC 7950 keyword atoms; preserve prefixed extension uses on rpc).
      # Flip back to main once both fixes are upstream.
      {:ex_yang, git: "https://github.com/imsmith/ex_yang.git", branch: "fix/rpc-extensions"},
```

- [ ] **Step 3: Fetch the new branch**

`mix deps.update ex_yang` — pulls the new SHA into `mix.lock`.

- [ ] **Step 4: Compile + verify existing tests**

```bash
mix compile --warnings-as-errors
mix test
```

Expected: clean compile, 421 tests 0 failures (current MCP suite still green).

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "Bump ex_yang to fix/rpc-extensions branch"
```

---

## Task 3: Canonical wagger-mcp-extensions.yang + smoke test

**Files:**
- Create: `yang/wagger-mcp-extensions.yang`
- Create: `test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`:

```elixir
defmodule Wagger.Generator.Mcp.WaggerMcpExtensionsTest do
  use ExUnit.Case, async: true

  @path Path.join(File.cwd!(), "yang/wagger-mcp-extensions.yang")

  setup_all do
    {:ok, source: File.read!(@path)}
  end

  test "parses successfully", %{source: source} do
    assert {:ok, _parsed} = ExYang.parse(source)
  end

  test "resolves against empty registry", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert {:ok, _resolved} = ExYang.resolve(parsed, %{})
  end

  test "module name and prefix", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert parsed.name == "wagger-mcp-extensions"
    assert parsed.prefix == "wagger-mcp"
  end

  test "revision date is 2026-04-27", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    assert Enum.any?(parsed.revisions, fn r -> r.date == "2026-04-27" end)
  end

  test "declares all eight extensions", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    names = Enum.map(parsed.extensions, & &1.name)
    for n <- ~w(tool-name resource-template prompt-name description-for-llm mime-type dangerous read-only exclude) do
      assert n in names, "missing extension: #{n}"
    end
  end

  test "argument-bearing extensions declare argument", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    by_name = Map.new(parsed.extensions, &{&1.name, &1})
    for n <- ~w(tool-name resource-template prompt-name description-for-llm mime-type) do
      assert by_name[n].argument != nil, "extension #{n} should have an argument"
    end
    for n <- ~w(dangerous read-only exclude) do
      assert by_name[n].argument == nil, "extension #{n} should not have an argument"
    end
  end
end
```

- [ ] **Step 2: Run test — expect FAIL (file missing)**

`mix test test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`

- [ ] **Step 3: Create `yang/wagger-mcp-extensions.yang`**

```yang
module wagger-mcp-extensions {
  yang-version 1.1;
  namespace "urn:wagger:mcp-extensions";
  prefix wagger-mcp;

  organization "Wagger";
  contact "https://github.com/imsmith/wagger";
  description
    "Annotation vocabulary for MCP capability projection. App YANG modules
     use these extensions to mark which RPCs are MCP tools/prompts, which
     containers and lists are resources, and to override LLM-facing names
     and descriptions.";
  reference "docs/superpowers/specs/2026-04-27-wagger-mcp-annotation-pipeline-design.md";

  revision 2026-04-27 {
    description "Initial vocabulary: 8 extensions for MCP capability annotation.";
  }

  extension tool-name {
    argument name;
    description "Override the auto-derived tool name on an `rpc`. Argument is the LLM-facing tool name (snake_case recommended).";
  }

  extension resource-template {
    argument template;
    description "Override the auto-derived URI template on a `list` or `container`. Argument is an RFC 6570 URI template string.";
  }

  extension prompt-name {
    argument name;
    description "Reclassify an `rpc` as an MCP prompt rather than a tool. Argument is the prompt name.";
  }

  extension description-for-llm {
    argument text;
    description "LLM-facing description, overrides the YANG `description` for MCP projection.";
  }

  extension mime-type {
    argument type;
    description "Resource MIME type. Defaults to `application/json` when absent.";
  }

  extension dangerous {
    description "Marks a tool as requiring user confirmation in the host (no argument).";
  }

  extension read-only {
    description "Marks a tool as side-effect-free, an MCP optimization hint (no argument).";
  }

  extension exclude {
    description "Opt this node out of MCP exposure (no argument). Counters the default-on policy.";
  }
}
```

- [ ] **Step 4: Run test — expect PASS (6 tests)**

`mix test test/wagger/generator/mcp/wagger_mcp_extensions_test.exs`

- [ ] **Step 5: Commit**

```bash
git add yang/wagger-mcp-extensions.yang test/wagger/generator/mcp/wagger_mcp_extensions_test.exs
git commit -m "Add wagger-mcp-extensions.yang annotation vocabulary"
```

---

## Task 4: Register derivation_failed error

**Files:** Modify `lib/wagger/errors.ex`.

- [ ] **Step 1: Add registration**

After the existing `register_error "wagger.generator/canonical_mcp_invalid", :internal, ...` block, add:

```elixir
  register_error "wagger.generator/derivation_failed", :validation,
    message: "Could not derive MCP capabilities from annotated YANG"
```

- [ ] **Step 2: Verify compilation**

`mix compile --warnings-as-errors` — expect clean.

- [ ] **Step 3: Commit**

```bash
git add lib/wagger/errors.ex
git commit -m "Register derivation_failed error ID"
```

---

## Task 5: Deriver — shared helpers (TDD)

Pure utility functions used by the per-primitive derivation tasks that follow.

**Files:**
- Create: `lib/wagger/generator/mcp/deriver.ex`
- Create: `test/wagger/generator/mcp/deriver_test.exs`

- [ ] **Step 1: Write failing test**

Create `test/wagger/generator/mcp/deriver_test.exs`:

```elixir
defmodule Wagger.Generator.Mcp.DeriverTest do
  use ExUnit.Case, async: true

  alias Wagger.Generator.Mcp.Deriver

  describe "kebab_to_snake/1" do
    test "converts kebab-case to snake_case" do
      assert Deriver.kebab_to_snake("create-note") == "create_note"
      assert Deriver.kebab_to_snake("a-b-c") == "a_b_c"
    end

    test "leaves already-snake input alone" do
      assert Deriver.kebab_to_snake("create_note") == "create_note"
    end

    test "leaves single-word input alone" do
      assert Deriver.kebab_to_snake("notes") == "notes"
    end
  end

  describe "extension_arg/2" do
    test "returns argument for a present extension" do
      ext = %ExYang.Model.ExtensionUse{
        keyword: {"wagger-mcp", "tool-name"},
        argument: "create_note"
      }

      assert Deriver.extension_arg([ext], "tool-name") == "create_note"
    end

    test "returns nil when extension absent" do
      assert Deriver.extension_arg([], "tool-name") == nil
    end

    test "ignores other prefixes" do
      ext = %ExYang.Model.ExtensionUse{
        keyword: {"other-prefix", "tool-name"},
        argument: "x"
      }

      assert Deriver.extension_arg([ext], "tool-name") == nil
    end
  end

  describe "extension_present?/2" do
    test "returns true when flag extension present" do
      ext = %ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "dangerous"}, argument: nil}
      assert Deriver.extension_present?([ext], "dangerous")
    end

    test "returns false when absent" do
      refute Deriver.extension_present?([], "dangerous")
    end
  end
end
```

- [ ] **Step 2: Run test — expect FAIL (module undefined)**

`mix test test/wagger/generator/mcp/deriver_test.exs`

- [ ] **Step 3: Implement Deriver helpers**

Create `lib/wagger/generator/mcp/deriver.ex`:

```elixir
defmodule Wagger.Generator.Mcp.Deriver do
  @moduledoc """
  Walks an annotated `ExYang.Model.Module{}` and produces a capability map
  consumable by `Wagger.Generator.Mcp.Builder.build_module/2`, plus a
  derivation report describing what was emitted, warnings, and excluded nodes.

  Default-on policy: every `rpc`, every keyed `list`, and every top-level
  `container` is exposed unless tagged with `wagger-mcp:exclude`. See
  the design doc at `docs/superpowers/specs/2026-04-27-wagger-mcp-annotation-pipeline-design.md`.
  """

  @prefix "wagger-mcp"

  @doc "Convert kebab-case identifier to snake_case."
  def kebab_to_snake(name) when is_binary(name), do: String.replace(name, "-", "_")

  @doc "Return the argument of the named wagger-mcp extension if present, else nil."
  def extension_arg(extensions, name) when is_list(extensions) and is_binary(name) do
    Enum.find_value(extensions, fn
      %ExYang.Model.ExtensionUse{keyword: {@prefix, ^name}, argument: arg} -> arg
      _ -> nil
    end)
  end

  @doc "Returns true if the named wagger-mcp flag extension is present."
  def extension_present?(extensions, name) when is_list(extensions) and is_binary(name) do
    Enum.any?(extensions, fn
      %ExYang.Model.ExtensionUse{keyword: {@prefix, ^name}} -> true
      _ -> false
    end)
  end
end
```

- [ ] **Step 4: Run test — expect PASS (7 tests)**

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/deriver.ex test/wagger/generator/mcp/deriver_test.exs
git commit -m "Add Deriver helpers (kebab→snake, extension lookup)"
```

---

## Task 6: Deriver — tool derivation (TDD)

**Files:**
- Modify: `lib/wagger/generator/mcp/deriver.ex`
- Modify: `test/wagger/generator/mcp/deriver_test.exs`

- [ ] **Step 1: Append failing test**

Inside `defmodule Wagger.Generator.Mcp.DeriverTest do`, append:

```elixir
  describe "derive_tools/1" do
    test "auto-derives tool name from rpc identifier (kebab→snake)" do
      rpc = %ExYang.Model.Rpc{name: "create-note", description: "Save a note.", extensions: []}
      assert {[tool], []} = Deriver.derive_tools([rpc])
      assert tool.name == "create_note"
      assert tool.description == "Save a note."
    end

    test "tool-name extension overrides auto-derived name" do
      rpc = %ExYang.Model.Rpc{
        name: "create-note",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "tool-name"}, argument: "createNote"}]
      }

      assert {[tool], _} = Deriver.derive_tools([rpc])
      assert tool.name == "createNote"
    end

    test "description-for-llm overrides YANG description" do
      rpc = %ExYang.Model.Rpc{
        name: "rpc1",
        description: "engineer doc",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "description-for-llm"}, argument: "llm doc"}]
      }

      assert {[tool], _} = Deriver.derive_tools([rpc])
      assert tool.description == "llm doc"
    end

    test "missing description falls back to identifier and emits warning" do
      rpc = %ExYang.Model.Rpc{name: "rpc1", extensions: []}
      assert {[tool], warnings} = Deriver.derive_tools([rpc])
      assert tool.description == "rpc1"
      assert Enum.any?(warnings, &(&1.node == "/rpcs/rpc1" and &1.kind == :description_fallback))
    end

    test "rpc with prompt-name is excluded from tools" do
      rpc = %ExYang.Model.Rpc{
        name: "summarize",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "prompt-name"}, argument: "summarize"}]
      }

      assert {[], _} = Deriver.derive_tools([rpc])
    end

    test "rpc with exclude is omitted" do
      rpc = %ExYang.Model.Rpc{
        name: "internal",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "exclude"}, argument: nil}]
      }

      assert {[], _} = Deriver.derive_tools([rpc])
    end

    test "dangerous and read-only flags are reflected in tool entry" do
      rpc = %ExYang.Model.Rpc{
        name: "purge",
        description: "Wipe everything.",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "dangerous"}, argument: nil}]
      }

      assert {[tool], _} = Deriver.derive_tools([rpc])
      assert tool.dangerous == true
      assert tool.read_only == false
    end

    test "duplicate auto-derived names produce error in second-pass detection" do
      rpcs = [
        %ExYang.Model.Rpc{name: "create-note", extensions: []},
        %ExYang.Model.Rpc{name: "create_note", extensions: []}
      ]

      # Both derive to "create_note"; derive_tools returns both, duplicates flagged later.
      assert {[t1, t2], _} = Deriver.derive_tools(rpcs)
      assert t1.name == t2.name
    end
  end
```

- [ ] **Step 2: Run test — expect FAIL (`derive_tools/1` undefined)**

- [ ] **Step 3: Implement derive_tools/1**

Append to `lib/wagger/generator/mcp/deriver.ex` (before final `end`):

```elixir
  @doc """
  Returns `{tools, warnings}` for the given list of `%ExYang.Model.Rpc{}` nodes.
  Excludes rpcs flagged with `wagger-mcp:exclude` or `wagger-mcp:prompt-name`.
  """
  def derive_tools(rpcs) when is_list(rpcs) do
    rpcs
    |> Enum.reduce({[], []}, fn rpc, {tools, warns} ->
      cond do
        extension_present?(rpc.extensions, "exclude") ->
          {tools, warns}

        extension_arg(rpc.extensions, "prompt-name") != nil ->
          {tools, warns}

        true ->
          {tool, warns_for_tool} = build_tool(rpc)
          {[tool | tools], warns ++ warns_for_tool}
      end
    end)
    |> then(fn {tools, warns} -> {Enum.reverse(tools), warns} end)
  end

  defp build_tool(%ExYang.Model.Rpc{} = rpc) do
    name = extension_arg(rpc.extensions, "tool-name") || kebab_to_snake(rpc.name)

    {description, warns} =
      case {extension_arg(rpc.extensions, "description-for-llm"), rpc.description} do
        {nil, nil} ->
          {rpc.name, [%{node: "/rpcs/#{rpc.name}", kind: :description_fallback, message: "no description-for-llm or YANG description; using identifier"}]}

        {nil, yang_desc} ->
          {yang_desc, []}

        {llm_desc, _} ->
          {llm_desc, []}
      end

    tool = %{
      name: name,
      description: description,
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"},
      dangerous: extension_present?(rpc.extensions, "dangerous"),
      read_only: extension_present?(rpc.extensions, "read-only")
    }

    {tool, warns}
  end
```

- [ ] **Step 4: Run test — expect PASS (15 tests total in file)**

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/deriver.ex test/wagger/generator/mcp/deriver_test.exs
git commit -m "Add Deriver.derive_tools/1"
```

---

## Task 7: Deriver — resource derivation (TDD)

**Files:**
- Modify: `lib/wagger/generator/mcp/deriver.ex`
- Modify: `test/wagger/generator/mcp/deriver_test.exs`

- [ ] **Step 1: Append failing test**

```elixir
  describe "derive_resources/1" do
    test "auto-derives URI template from keyed list name and key leaf" do
      list = %ExYang.Model.List{name: "notes", key: "id", body: []}
      assert {[res], []} = Deriver.derive_resources([list])
      assert res.uri_template == "notes://{id}"
      assert res.name == "notes"
    end

    test "resource-template extension overrides default" do
      list = %ExYang.Model.List{
        name: "notes",
        key: "id",
        body: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "resource-template"}, argument: "/api/notes/{id}"}]
      }

      assert {[res], _} = Deriver.derive_resources([list])
      assert res.uri_template == "/api/notes/{id}"
    end

    test "list without key produces derivation error in errors output" do
      list = %ExYang.Model.List{name: "notes", key: nil, body: []}
      assert {[], errors} = Deriver.derive_resources([list])
      assert Enum.any?(errors, &(&1.node == "/lists/notes" and &1.kind == :missing_key))
    end

    test "top-level container produces resource with simple URI" do
      container = %ExYang.Model.Container{name: "config", body: []}
      assert {[res], _} = Deriver.derive_resources([container])
      assert res.uri_template == "config://"
    end

    test "exclude omits the node" do
      list = %ExYang.Model.List{
        name: "notes",
        key: "id",
        body: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "exclude"}, argument: nil}]
      }

      assert {[], []} = Deriver.derive_resources([list])
    end

    test "mime-type override" do
      list = %ExYang.Model.List{
        name: "files",
        key: "path",
        body: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "mime-type"}, argument: "application/octet-stream"}]
      }

      assert {[res], _} = Deriver.derive_resources([list])
      assert res.mime_type == "application/octet-stream"
    end

    test "missing mime-type defaults to application/json with warning" do
      list = %ExYang.Model.List{name: "notes", key: "id", body: []}
      assert {[res], warns} = Deriver.derive_resources([list])
      assert res.mime_type == "application/json"
      assert Enum.any?(warns, &(&1.kind == :mime_type_default))
    end

    test "resource-template missing {var} on keyed list is an error" do
      list = %ExYang.Model.List{
        name: "notes",
        key: "id",
        body: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "resource-template"}, argument: "/api/notes"}]
      }

      assert {[], errors} = Deriver.derive_resources([list])
      assert Enum.any?(errors, &(&1.kind == :uri_template_missing_var))
    end
  end
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement derive_resources/1**

Append to `lib/wagger/generator/mcp/deriver.ex`:

```elixir
  @doc """
  Returns `{resources, issues}` where issues is a list of warning OR error maps.
  Errors carry `kind: :missing_key | :uri_template_missing_var`. Warnings carry
  `kind: :mime_type_default | :description_fallback`.
  """
  def derive_resources(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce({[], []}, fn node, {acc, issues} ->
      cond do
        excluded?(node) ->
          {acc, issues}

        true ->
          case build_resource(node) do
            {:ok, res, warns} -> {[res | acc], issues ++ warns}
            {:error, err} -> {acc, issues ++ [err]}
          end
      end
    end)
    |> then(fn {acc, issues} -> {Enum.reverse(acc), issues} end)
  end

  defp excluded?(%{body: body}) when is_list(body), do: extension_present?(body, "exclude")
  defp excluded?(_), do: false

  defp body_extensions(%{body: body}) when is_list(body) do
    Enum.filter(body, &match?(%ExYang.Model.ExtensionUse{keyword: {@prefix, _}}, &1))
  end
  defp body_extensions(_), do: []

  defp build_resource(%ExYang.Model.List{name: name, key: nil}) do
    {:error, %{node: "/lists/#{name}", kind: :missing_key, message: "list has no key; cannot auto-derive URI template"}}
  end

  defp build_resource(%ExYang.Model.List{name: name, key: key} = list) do
    exts = body_extensions(list)

    {template, template_errors} =
      case extension_arg(exts, "resource-template") do
        nil ->
          {"#{name}://{#{key}}", []}

        explicit ->
          if String.contains?(explicit, "{") and String.contains?(explicit, "}") do
            {explicit, []}
          else
            {nil, [%{node: "/lists/#{name}", kind: :uri_template_missing_var, message: "resource-template must contain at least one {var} for keyed list"}]}
          end
      end

    if template == nil do
      [error] = template_errors
      {:error, error}
    else
      {mime, mime_warns} = mime_type_for(exts, "/lists/#{name}")

      {:ok,
       %{
         uri_template: template,
         name: name,
         mime_type: mime,
         description: list.description || name
       }, mime_warns}
    end
  end

  defp build_resource(%ExYang.Model.Container{name: name} = container) do
    exts = body_extensions(container)

    template =
      case extension_arg(exts, "resource-template") do
        nil -> "#{name}://"
        explicit -> explicit
      end

    {mime, mime_warns} = mime_type_for(exts, "/containers/#{name}")

    {:ok,
     %{
       uri_template: template,
       name: name,
       mime_type: mime,
       description: container.description || name
     }, mime_warns}
  end

  defp mime_type_for(exts, path) do
    case extension_arg(exts, "mime-type") do
      nil ->
        {"application/json",
         [%{node: path, kind: :mime_type_default, message: "no mime-type set; defaulting to application/json"}]}

      mime ->
        {mime, []}
    end
  end
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/deriver.ex test/wagger/generator/mcp/deriver_test.exs
git commit -m "Add Deriver.derive_resources/1"
```

---

## Task 8: Deriver — prompt derivation + full derive/2 (TDD)

**Files:**
- Modify: `lib/wagger/generator/mcp/deriver.ex`
- Modify: `test/wagger/generator/mcp/deriver_test.exs`

- [ ] **Step 1: Append failing tests**

```elixir
  describe "derive_prompts/1" do
    test "rpc with prompt-name becomes a prompt" do
      rpc = %ExYang.Model.Rpc{
        name: "summarize",
        description: "Summarize text.",
        extensions: [%ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "prompt-name"}, argument: "summarize"}]
      }

      assert {[prompt], _} = Deriver.derive_prompts([rpc])
      assert prompt.name == "summarize"
    end

    test "rpc without prompt-name is excluded" do
      rpc = %ExYang.Model.Rpc{name: "create-note", extensions: []}
      assert {[], _} = Deriver.derive_prompts([rpc])
    end

    test "exclude takes precedence" do
      rpc = %ExYang.Model.Rpc{
        name: "summarize",
        extensions: [
          %ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "prompt-name"}, argument: "summarize"},
          %ExYang.Model.ExtensionUse{keyword: {"wagger-mcp", "exclude"}, argument: nil}
        ]
      }

      assert {[], _} = Deriver.derive_prompts([rpc])
    end
  end

  describe "derive/2" do
    test "produces a complete capability map and report from a parsed module" do
      yang = """
      module demo {
        yang-version 1.1;
        namespace "urn:demo";
        prefix demo;
        revision 2026-04-27 { description "x"; }
        rpc create-note {
          description "Save a note.";
        }
        list notes {
          key id;
          leaf id { type string; }
        }
        container config {
        }
      }
      """

      {:ok, parsed} = ExYang.parse(yang)
      assert {:ok, caps, report} = Deriver.derive(parsed, "demo")
      assert caps.app_name == "demo"
      assert length(caps.tools) == 1
      assert length(caps.resources) == 2
      assert caps.prompts == []
      assert report.tools_count == 1
      assert report.resources_count == 2
      assert report.prompts_count == 0
    end

    test "duplicate auto-derived tool names are reported as derivation_failed" do
      yang = """
      module dup {
        yang-version 1.1;
        namespace "urn:dup";
        prefix dup;
        revision 2026-04-27 { description "x"; }
        rpc foo-bar { }
        rpc foo_bar { }
      }
      """

      {:ok, parsed} = ExYang.parse(yang)
      assert {:error, errors} = Deriver.derive(parsed, "dup")
      assert Enum.any?(errors, &(&1.kind == :duplicate_tool_name))
    end
  end
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement derive_prompts/1 and derive/2**

Append to `lib/wagger/generator/mcp/deriver.ex`:

```elixir
  @doc """
  Returns `{prompts, warnings}`. Only rpcs with `wagger-mcp:prompt-name` are
  prompts; exclude takes precedence.
  """
  def derive_prompts(rpcs) when is_list(rpcs) do
    rpcs
    |> Enum.reduce({[], []}, fn rpc, {acc, warns} ->
      cond do
        extension_present?(rpc.extensions, "exclude") ->
          {acc, warns}

        extension_arg(rpc.extensions, "prompt-name") == nil ->
          {acc, warns}

        true ->
          {prompt, w} = build_prompt(rpc)
          {[prompt | acc], warns ++ w}
      end
    end)
    |> then(fn {acc, warns} -> {Enum.reverse(acc), warns} end)
  end

  defp build_prompt(%ExYang.Model.Rpc{} = rpc) do
    name = extension_arg(rpc.extensions, "prompt-name")

    {description, warns} =
      case {extension_arg(rpc.extensions, "description-for-llm"), rpc.description} do
        {nil, nil} ->
          {rpc.name, [%{node: "/rpcs/#{rpc.name}", kind: :description_fallback, message: "no description; using identifier"}]}

        {nil, d} -> {d, []}
        {d, _} -> {d, []}
      end

    {%{name: name, description: description, arguments: []}, warns}
  end

  @doc """
  Walks a parsed YANG module and produces a capability map plus a derivation
  report. Returns `{:ok, capability_map, report}` or `{:error, [errors]}`.

  `capability_map` is the shape consumed by `Wagger.Generator.Mcp.Builder.build_module/2`.
  """
  def derive(parsed_module, app_name) when is_binary(app_name) do
    rpcs = parsed_module.rpcs || []
    body = parsed_module.body || []

    lists = Enum.filter(body, &match?(%ExYang.Model.List{}, &1))
    containers = Enum.filter(body, &match?(%ExYang.Model.Container{}, &1))

    {tools, tool_warns} = derive_tools(rpcs)
    {resources, resource_issues} = derive_resources(lists ++ containers)
    {prompts, prompt_warns} = derive_prompts(rpcs)

    excluded_nodes = collect_excluded(rpcs, lists ++ containers)

    {warnings, errors} = split_issues(resource_issues)
    warnings = warnings ++ tool_warns ++ prompt_warns

    duplicate_errors = check_duplicate_tools(tools)

    case errors ++ duplicate_errors do
      [] ->
        caps = %{
          app_name: app_name,
          tools: tools,
          resources: resources,
          prompts: prompts
        }

        report = %{
          tools_count: length(tools),
          resources_count: length(resources),
          prompts_count: length(prompts),
          tools: tools,
          resources: resources,
          prompts: prompts,
          warnings: warnings,
          excluded: excluded_nodes
        }

        {:ok, caps, report}

      es ->
        {:error, es}
    end
  end

  defp split_issues(issues) do
    Enum.split_with(issues, fn %{kind: k} ->
      k in [:mime_type_default, :description_fallback]
    end)
  end

  defp collect_excluded(rpcs, body) do
    rpc_excl = for rpc <- rpcs, extension_present?(rpc.extensions, "exclude"), do: "/rpcs/#{rpc.name}"
    body_excl =
      for n <- body, excluded?(n) do
        case n do
          %ExYang.Model.List{name: name} -> "/lists/#{name}"
          %ExYang.Model.Container{name: name} -> "/containers/#{name}"
        end
      end

    rpc_excl ++ body_excl
  end

  defp check_duplicate_tools(tools) do
    names = Enum.map(tools, & &1.name)
    dups = names -- Enum.uniq(names)

    Enum.map(Enum.uniq(dups), fn n ->
      %{node: "/tools/#{n}", kind: :duplicate_tool_name, message: "duplicate tool name: #{n}"}
    end)
  end
```

- [ ] **Step 4: Run — expect PASS**

- [ ] **Step 5: Commit**

```bash
git add lib/wagger/generator/mcp/deriver.ex test/wagger/generator/mcp/deriver_test.exs
git commit -m "Add Deriver.derive_prompts/1 and Deriver.derive/2"
```

---

## Task 9: Mcp.generate_from_yang/2 entry + integration tests

**Files:**
- Modify: `lib/wagger/generator/mcp.ex`
- Modify: `test/wagger/generator/mcp_test.exs`
- Create: `test/support/fixtures/mcp/annotated_service.yang`
- Create: `test/support/fixtures/mcp/annotated_service-mcp.yang`

- [ ] **Step 1: Create input fixture**

`test/support/fixtures/mcp/annotated_service.yang`:

```yang
module notes-service {
  yang-version 1.1;
  namespace "urn:example:notes";
  prefix notes;
  import wagger-mcp-extensions { prefix wagger-mcp; }
  revision 2026-04-27 { description "Initial."; }

  rpc create-note {
    wagger-mcp:dangerous;
    description "Create a new note.";
  }

  rpc search-notes {
    wagger-mcp:read-only;
    wagger-mcp:description-for-llm "Full-text search across notes. Use when user asks to find by content.";
    description "Search notes.";
  }

  rpc internal-vacuum {
    wagger-mcp:exclude;
    description "Internal maintenance, not LLM-callable.";
  }

  rpc summarize-notes {
    wagger-mcp:prompt-name "summarize";
    description "Summarize a set of notes.";
  }

  list notes {
    key id;
    leaf id { type string; }
    leaf title { type string; }
    leaf body { type string; }
  }

  container config {
    description "Service configuration.";
    leaf default-mime { type string; }
  }
}
```

- [ ] **Step 2: Append failing test to `test/wagger/generator/mcp_test.exs`**

```elixir
  describe "generate_from_yang/2" do
    @fixture_in "test/support/fixtures/mcp/annotated_service.yang"
    @fixture_out "test/support/fixtures/mcp/annotated_service-mcp.yang"

    test "round-trip on annotated fixture" do
      source = File.read!(@fixture_in)
      assert {:ok, yang_text, report} = Wagger.Generator.Mcp.generate_from_yang(source, "notes-service")
      assert report.tools_count == 2
      assert report.resources_count == 2
      assert report.prompts_count == 1
      assert yang_text =~ "module notes-service-mcp"
      assert yang_text =~ "import mcp"
      assert {:ok, _} = ExYang.parse(yang_text)
    end

    test "matches golden fixture" do
      source = File.read!(@fixture_in)
      {:ok, yang_text, _} = Wagger.Generator.Mcp.generate_from_yang(source, "notes-service")
      normalized = Regex.replace(~r/revision \d{4}-\d{2}-\d{2}/, yang_text, "revision YYYY-MM-DD")
      assert normalized == File.read!(@fixture_out)
    end

    test "parse failure surfaces yang_parse_failed" do
      assert {:error, err} = Wagger.Generator.Mcp.generate_from_yang("not yang", "x")
      assert err.code == "wagger.generator/yang_parse_failed"
    end

    test "derivation conflict surfaces derivation_failed" do
      yang = """
      module dup {
        yang-version 1.1;
        namespace "urn:dup";
        prefix dup;
        revision 2026-04-27 { description "x"; }
        rpc foo-bar { }
        rpc foo_bar { }
      }
      """

      assert {:error, err} = Wagger.Generator.Mcp.generate_from_yang(yang, "dup")
      assert err.code == "wagger.generator/derivation_failed"
    end
  end
```

- [ ] **Step 3: Run — expect FAIL (`generate_from_yang/2` undefined)**

`mix test test/wagger/generator/mcp_test.exs`

- [ ] **Step 4: Implement generate_from_yang/2**

Append to `lib/wagger/generator/mcp.ex` (before final `end`):

```elixir
  @extensions_resource Path.join([__DIR__, "..", "..", "..", "yang", "wagger-mcp-extensions.yang"])
  @external_resource @extensions_resource
  @extensions_source File.read!(@extensions_resource)

  @doc """
  End-to-end: annotated YANG source text + app_name → generated `my-app-mcp.yang`
  source text plus a derivation report. Returns `{:ok, yang_text, report}` or
  `{:error, ErrorStruct.t()}`.
  """
  def generate_from_yang(source, app_name) when is_binary(source) and is_binary(app_name) do
    with {:ok, parsed} <- parse(source),
         {:ok, _resolved} <- resolve(parsed),
         {:ok, caps, report} <- derive(parsed, app_name),
         {:ok, module_struct} <- Wagger.Generator.Mcp.Builder.build_module(caps, %{}),
         {:ok, yang_text} <- ExYang.Encoder.Encoder.encode(module_struct) do
      {:ok, yang_text, report}
    end
  end

  defp parse(source) do
    case ExYang.parse(source) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_parse_failed",
           message: inspect(reason)
         )}
    end
  end

  defp resolve(parsed) do
    {:ok, ext_parsed} = ExYang.parse(@extensions_source)
    {:ok, ext_resolved} = ExYang.resolve(ext_parsed, %{})
    registry = %{ext_resolved.module.name => ext_resolved.module}

    case ExYang.resolve(parsed, registry) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_resolve_failed",
           message: inspect(reason)
         )}
    end
  end

  defp derive(parsed, app_name) do
    case Wagger.Generator.Mcp.Deriver.derive(parsed, app_name) do
      {:ok, caps, report} ->
        {:ok, caps, report}

      {:error, errors} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/derivation_failed",
           message: errors |> Enum.map_join("; ", & &1.message),
           field: errors |> List.first() |> Map.get(:node)
         )}
    end
  end
```

- [ ] **Step 5: Generate golden fixture**

```bash
mix run -e '
  source = File.read!("test/support/fixtures/mcp/annotated_service.yang")
  {:ok, yang_text, _} = Wagger.Generator.Mcp.generate_from_yang(source, "notes-service")
  normalized = Regex.replace(~r/revision \d{4}-\d{2}-\d{2}/, yang_text, "revision YYYY-MM-DD")
  File.write!("test/support/fixtures/mcp/annotated_service-mcp.yang", normalized)
'
```

- [ ] **Step 6: Inspect fixture**

`cat test/support/fixtures/mcp/annotated_service-mcp.yang` — sanity check: `module notes-service-mcp`, imports `mcp`, three primitive containers (`tools`, `resources`, `prompts`) populated, revision normalized.

- [ ] **Step 7: Run all 4 tests — expect PASS**

`mix test test/wagger/generator/mcp_test.exs`

- [ ] **Step 8: Commit**

```bash
git add lib/wagger/generator/mcp.ex test/wagger/generator/mcp_test.exs test/support/fixtures/mcp/
git commit -m "Add Mcp.generate_from_yang/2 with golden-fixture integration test"
```

---

## Task 10: McpDownloadController + token-signed download (TDD)

**Files:**
- Create: `lib/wagger_web/controllers/mcp_download_controller.ex`
- Create: `test/wagger_web/controllers/mcp_download_controller_test.exs`
- Modify: `lib/wagger_web/router.ex` (add route)

- [ ] **Step 1: Add route**

In `lib/wagger_web/router.ex`, find the API/scope block where `GenerateController` is defined and add:

```elixir
    get "/mcp/download/:token", McpDownloadController, :show
```

inside an unauthenticated browser scope (find the `scope "/", WaggerWeb do` browser block and add it there alongside live routes).

- [ ] **Step 2: Write failing test**

Create `test/wagger_web/controllers/mcp_download_controller_test.exs`:

```elixir
defmodule WaggerWeb.McpDownloadControllerTest do
  use WaggerWeb.ConnCase

  @salt "mcp-download"
  @max_age 300

  test "valid token returns YANG body with attachment header", %{conn: conn} do
    payload = %{yang_text: "module x {}", filename: "x-mcp.yang"}
    token = Phoenix.Token.sign(WaggerWeb.Endpoint, @salt, payload)

    conn = get(conn, ~p"/mcp/download/#{token}")
    assert conn.status == 200
    assert response(conn, 200) == "module x {}"
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/yang"
    assert get_resp_header(conn, "content-disposition") |> List.first() =~ "attachment; filename=\"x-mcp.yang\""
  end

  test "expired token returns 410", %{conn: conn} do
    payload = %{yang_text: "x", filename: "x.yang"}
    token = Phoenix.Token.sign(WaggerWeb.Endpoint, @salt, payload, signed_at: 0)

    assert_error_sent 410, fn -> get(conn, ~p"/mcp/download/#{token}") end
  end

  test "garbage token returns 403", %{conn: conn} do
    assert_error_sent 403, fn -> get(conn, ~p"/mcp/download/garbage") end
  end
end
```

- [ ] **Step 3: Run — expect FAIL (controller missing)**

- [ ] **Step 4: Implement controller**

Create `lib/wagger_web/controllers/mcp_download_controller.ex`:

```elixir
defmodule WaggerWeb.McpDownloadController do
  @moduledoc """
  Serves a one-shot download for a `Phoenix.Token`-signed payload of
  `%{yang_text, filename}`. Tokens expire after 5 minutes (signed at issue time).
  """

  use WaggerWeb, :controller

  @salt "mcp-download"
  @max_age 300

  def show(conn, %{"token" => token}) do
    case Phoenix.Token.verify(WaggerWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{yang_text: yang_text, filename: filename}} ->
        conn
        |> put_resp_content_type("application/yang")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> send_resp(200, yang_text)

      {:error, :expired} ->
        send_resp(conn, 410, "expired")

      {:error, _} ->
        send_resp(conn, 403, "forbidden")
    end
  end
end
```

- [ ] **Step 5: Run tests — expect PASS**

- [ ] **Step 6: Commit**

```bash
git add lib/wagger_web/controllers/mcp_download_controller.ex test/wagger_web/controllers/mcp_download_controller_test.exs lib/wagger_web/router.ex
git commit -m "Add McpDownloadController with token-signed download"
```

---

## Task 11: McpGeneratorLive (TDD)

**Files:**
- Create: `lib/wagger_web/live/mcp_generator_live.ex`
- Create: `lib/wagger_web/live/mcp_generator_live.html.heex`
- Create: `test/wagger_web/live/mcp_generator_live_test.exs`
- Modify: `lib/wagger_web/router.ex` (add live route)

- [ ] **Step 1: Add live route**

In `lib/wagger_web/router.ex`, alongside other `live` declarations:

```elixir
      live "/mcp", McpGeneratorLive, :index
```

- [ ] **Step 2: Write failing LiveView test**

Create `test/wagger_web/live/mcp_generator_live_test.exs`:

```elixir
defmodule WaggerWeb.McpGeneratorLiveTest do
  use WaggerWeb.ConnCase
  import Phoenix.LiveViewTest

  @valid_yang """
  module demo {
    yang-version 1.1;
    namespace "urn:demo";
    prefix demo;
    revision 2026-04-27 { description "x"; }
    rpc create-note { description "Save a note."; }
    list notes { key id; leaf id { type string; } }
  }
  """

  test "mount renders textarea and submit button", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/mcp")
    assert html =~ "MCP Generator"
    assert html =~ ~s(name="yang_source")
    assert html =~ "Generate"
    refute html =~ "Derivation report"
  end

  test "submit valid YANG renders report and download link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    html =
      view
      |> form("#mcp-form", %{"yang_source" => @valid_yang})
      |> render_submit()

    assert html =~ "Derivation report"
    assert html =~ "1 tool"
    assert html =~ "1 resource"
    assert html =~ "create_note"
    assert html =~ "/mcp/download/"
  end

  test "submit invalid YANG renders error card without download link", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    html =
      view
      |> form("#mcp-form", %{"yang_source" => "garbage"})
      |> render_submit()

    assert html =~ "wagger.generator/yang_parse_failed"
    refute html =~ "/mcp/download/"
  end
end
```

- [ ] **Step 3: Run — expect FAIL (route + view missing)**

- [ ] **Step 4: Implement LiveView module**

Create `lib/wagger_web/live/mcp_generator_live.ex`:

```elixir
defmodule WaggerWeb.McpGeneratorLive do
  @moduledoc """
  Standalone page for generating an MCP module from annotated YANG.

  Stateless one-shot: paste/upload YANG → submit → derivation report,
  generated YANG source, and a token-signed download link rendered inline.
  """

  use WaggerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, result: nil, source: "")}
  end

  @impl true
  def handle_event("generate", %{"yang_source" => source}, socket) do
    app_name = derive_app_name(source)

    case Wagger.Generator.Mcp.generate_from_yang(source, app_name) do
      {:ok, yang_text, report} ->
        filename = "#{app_name}-mcp.yang"
        token = Phoenix.Token.sign(WaggerWeb.Endpoint, "mcp-download", %{yang_text: yang_text, filename: filename})

        {:noreply,
         assign(socket,
           result: {:ok, %{yang_text: yang_text, report: report, filename: filename, token: token}},
           source: source
         )}

      {:error, err} ->
        {:noreply, assign(socket, result: {:error, err}, source: source)}
    end
  end

  defp derive_app_name(source) do
    case Regex.run(~r/^\s*module\s+([a-zA-Z0-9_\-\.]+)/m, source) do
      [_, name] -> String.replace_suffix(name, "-mcp", "")
      _ -> "service"
    end
  end
end
```

- [ ] **Step 5: Implement template**

Create `lib/wagger_web/live/mcp_generator_live.html.heex`:

```heex
<Layouts.app flash={@flash} current_scope={@current_scope}>
  <div class="max-w-5xl mx-auto p-6 space-y-6">
    <header>
      <h1 class="text-2xl font-bold">MCP Generator</h1>
      <p class="text-sm text-gray-600">
        Paste annotated YANG; receive a generated <code>my-service-mcp.yang</code> module
        plus a derivation report. Use <code>wagger-mcp:*</code> extensions to override
        auto-derivation. Stateless — nothing is stored.
      </p>
    </header>

    <form id="mcp-form" phx-submit="generate" class="space-y-4">
      <textarea
        name="yang_source"
        rows="20"
        class="w-full font-mono text-xs border rounded p-2"
        placeholder="module my-service { ... }"
      ><%= @source %></textarea>
      <button type="submit" class="px-4 py-2 bg-indigo-600 text-white rounded hover:bg-indigo-700">
        Generate
      </button>
    </form>

    <%= case @result do %>
      <% nil -> %>
        <%= nil %>
      <% {:ok, %{yang_text: yang_text, report: report, filename: filename, token: token}} -> %>
        <section class="border rounded p-4 space-y-4">
          <h2 class="text-lg font-semibold">Derivation report</h2>
          <p class="text-sm">
            <%= report.tools_count %> tool<%= if report.tools_count == 1, do: "", else: "s" %>,
            <%= report.resources_count %> resource<%= if report.resources_count == 1, do: "", else: "s" %>,
            <%= report.prompts_count %> prompt<%= if report.prompts_count == 1, do: "", else: "s" %>.
          </p>

          <%= if report.warnings != [] do %>
            <div class="border-l-4 border-yellow-400 bg-yellow-50 p-3">
              <h3 class="font-semibold text-yellow-800">Warnings</h3>
              <ul class="text-sm">
                <%= for w <- report.warnings do %>
                  <li><code><%= w.node %></code>: <%= w.message %></li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <%= if report.excluded != [] do %>
            <div class="text-sm">
              <h3 class="font-semibold">Excluded</h3>
              <ul><%= for n <- report.excluded do %><li><code><%= n %></code></li><% end %></ul>
            </div>
          <% end %>

          <details>
            <summary class="cursor-pointer font-semibold">Tools (<%= report.tools_count %>)</summary>
            <table class="text-sm w-full">
              <thead><tr><th>name</th><th>description</th><th>flags</th></tr></thead>
              <tbody>
                <%= for t <- report.tools do %>
                  <tr>
                    <td><code><%= t.name %></code></td>
                    <td><%= t.description %></td>
                    <td>
                      <%= if t.dangerous, do: "dangerous " %>
                      <%= if t.read_only, do: "read-only" %>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </details>

          <details>
            <summary class="cursor-pointer font-semibold">Resources (<%= report.resources_count %>)</summary>
            <ul class="text-sm">
              <%= for r <- report.resources do %>
                <li><code><%= r.uri_template %></code> — <%= r.mime_type %></li>
              <% end %>
            </ul>
          </details>

          <details>
            <summary class="cursor-pointer font-semibold">Prompts (<%= report.prompts_count %>)</summary>
            <ul class="text-sm">
              <%= for p <- report.prompts do %>
                <li><code><%= p.name %></code> — <%= p.description %></li>
              <% end %>
            </ul>
          </details>
        </section>

        <section class="border rounded p-4 space-y-2">
          <div class="flex justify-between items-center">
            <h2 class="text-lg font-semibold">Generated YANG</h2>
            <a href={~p"/mcp/download/#{token}"} class="px-3 py-1 bg-green-600 text-white rounded text-sm">
              Download <%= filename %>
            </a>
          </div>
          <pre class="bg-gray-50 p-3 text-xs overflow-x-auto"><code><%= yang_text %></code></pre>
        </section>
      <% {:error, err} -> %>
        <section class="border-l-4 border-red-500 bg-red-50 p-4">
          <h2 class="font-bold text-red-800">Generation failed</h2>
          <p class="text-sm"><code><%= err.code %></code></p>
          <p class="text-sm"><%= err.message %></p>
        </section>
    <% end %>
  </div>
</Layouts.app>
```

- [ ] **Step 6: Run tests — expect PASS**

`mix test test/wagger_web/live/mcp_generator_live_test.exs`

- [ ] **Step 7: Commit**

```bash
git add lib/wagger_web/live/mcp_generator_live.ex lib/wagger_web/live/mcp_generator_live.html.heex test/wagger_web/live/mcp_generator_live_test.exs lib/wagger_web/router.ex
git commit -m "Add McpGeneratorLive with paste-and-render flow"
```

---

## Task 12: Final precommit + branch finishing

- [ ] **Step 1: mix precommit**

`mix precommit` — expect clean.

- [ ] **Step 2: Full test sweep, three seeds**

```bash
for s in 1 2 3; do mix test --seed $s 2>&1 | tail -2; done
```

Expected: 0 failures across all three.

- [ ] **Step 3: Revert any unrelated `mix format` drift**

`git status --short` — if any files outside the MCP feature were touched by format, revert them with `git checkout -- <path>`.

- [ ] **Step 4: Verify branch state**

```bash
git log --oneline main..HEAD
```

Expected: 11 commits (Tasks 2-11; Task 1 is in the ex_yang fork, not this branch).

- [ ] **Step 5: Hand off to finishing-a-development-branch skill**

Stop here. Report DONE with summary; the controller invokes `superpowers:finishing-a-development-branch` to decide merge/PR.
