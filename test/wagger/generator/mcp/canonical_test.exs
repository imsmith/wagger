defmodule Wagger.Generator.Mcp.CanonicalTest do
  @moduledoc false
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

  test "Builder @canonical_revision matches canonical yang/mcp.yang revision", %{source: source} do
    {:ok, parsed} = ExYang.parse(source)
    [canonical_rev | _] = parsed.revisions
    # Module attribute is private; read via the emitted Import statement shape
    # by building a tiny module and pulling the revision_date off the import.
    {:ok, module} = Wagger.Generator.Mcp.Builder.build_module(%{app_name: "probe"}, %{})
    [%ExYang.Model.Import{revision_date: emitted}] = module.imports
    assert emitted == canonical_rev.date,
           "Builder.@canonical_revision (#{emitted}) drifted from yang/mcp.yang revision (#{canonical_rev.date})"
  end
end
