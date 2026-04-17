defmodule Wagger.Generator.McpTest do
  @moduledoc false
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

      normalized = Regex.replace(~r/revision \d{4}-\d{2}-\d{2}/, source, "revision YYYY-MM-DD")

      expected = File.read!(@fixture_path)
      assert normalized == expected
    end
  end
end
