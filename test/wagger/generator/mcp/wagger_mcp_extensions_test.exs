defmodule Wagger.Generator.Mcp.WaggerMcpExtensionsTest do
  @moduledoc false
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
