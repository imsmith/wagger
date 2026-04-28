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
          {rpc.name,
           [
             %{
               node: "/rpcs/#{rpc.name}",
               kind: :description_fallback,
               message: "no description-for-llm or YANG description; using identifier"
             }
           ]}

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
end
