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
