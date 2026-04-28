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
end
