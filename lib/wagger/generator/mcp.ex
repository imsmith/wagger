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

  @extensions_resource Path.join([__DIR__, "..", "..", "..", "yang", "wagger-mcp-extensions.yang"])
  @external_resource @extensions_resource
  @extensions_source File.read!(@extensions_resource)

  @doc """
  End-to-end: annotated YANG source text + app_name → generated `my-app-mcp.yang`
  source text plus a derivation report. Returns `{:ok, yang_text, report}` or
  `{:error, ErrorStruct.t()}`.
  """
  def generate_from_yang(source, app_name) when is_binary(source) and is_binary(app_name) do
    with {:ok, parsed} <- parse_app_yang(source),
         {:ok, _resolved} <- resolve_app_yang(parsed),
         {:ok, caps, report} <- derive_caps(parsed, app_name),
         {:ok, module_struct} <- Builder.build_module(caps, %{}),
         {:ok, yang_text} <- ExYang.Encoder.Encoder.encode(module_struct) do
      {:ok, yang_text, report}
    end
  end

  defp parse_app_yang(source) do
    case ExYang.parse(source) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_parse_failed",
           message: inspect(reason)
         )}
    end
  end

  defp resolve_app_yang(parsed) do
    {:ok, ext_parsed} = ExYang.parse(@extensions_source)
    {:ok, ext_resolved} = ExYang.resolve(ext_parsed, %{})
    registry = %{ext_resolved.module.name => ext_resolved.module}

    case ExYang.resolve(parsed, registry) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_resolve_failed",
           message: inspect(reason)
         )}
    end
  end

  defp derive_caps(parsed, app_name) do
    case Wagger.Generator.Mcp.Deriver.derive(parsed, app_name) do
      {:ok, caps, report} ->
        {:ok, caps, report}

      {:error, errors} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/derivation_failed",
           message: errors |> Enum.map_join("; ", & &1.message),
           field: errors |> List.first() |> Map.get(:node)
         )}
    end
  end
end
