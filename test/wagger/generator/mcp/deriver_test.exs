defmodule Wagger.Generator.Mcp.DeriverTest do
  @moduledoc false
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

      # Both derive to "create_note"; derive_tools returns both; duplicates flagged later.
      assert {[t1, t2], _} = Deriver.derive_tools(rpcs)
      assert t1.name == t2.name
    end
  end

  describe "derive_resources/1" do
    test "auto-derives URI template from keyed list name and key leaf" do
      list = %ExYang.Model.List{name: "notes", key: "id", body: []}
      assert {[res], warns_or_errors} = Deriver.derive_resources([list])
      assert res.uri_template == "notes://{id}"
      assert res.name == "notes"
      assert is_list(warns_or_errors)
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
end
