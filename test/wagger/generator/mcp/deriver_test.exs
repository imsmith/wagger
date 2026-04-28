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
end
