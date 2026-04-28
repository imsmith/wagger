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
end
