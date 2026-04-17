defmodule Wagger.Generator.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) generator implementing the `Wagger.Generator`
  behaviour via the capability pipeline.

  Emits a per-application YANG module (`my-app-mcp.yang`) that imports the
  canonical `mcp.yang` shipped with wagger. Input is a flat capability map
  describing tools, resources, and prompts; output is YANG source text.

  See `docs/superpowers/specs/2026-04-17-wagger-mcp-provider-design.md`.
  """

  @behaviour Wagger.Generator

  alias Wagger.Generator.Mcp.Builder

  @external_resource Path.join([__DIR__, "..", "..", "..", "yang", "mcp.yang"])
  @canonical_source File.read!(@external_resource)

  @impl true
  def yang_module, do: @canonical_source

  @impl true
  def map_capabilities(capabilities, config) do
    case Builder.build_module(capabilities, config) do
      {:ok, module} ->
        {:ok, module}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/invalid_capabilities",
           message: format_reason(reason),
           field: field_for_reason(reason)
         )}
    end
  end

  defp format_reason({:missing, field}), do: "Required field missing: #{field}"

  defp format_reason({:invalid_identifier, field, value}),
    do: "Field #{field} is not a valid YANG identifier: #{inspect(value)}"

  defp format_reason({:duplicate, collection, name}),
    do: "Duplicate entry in #{collection}: #{inspect(name)}"

  defp field_for_reason({:missing, field}), do: field
  defp field_for_reason({:invalid_identifier, field, _}), do: field
  defp field_for_reason({:duplicate, collection, _}), do: collection
end
