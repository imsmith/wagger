defmodule Wagger.Generator do
  @moduledoc """
  Behaviour and shared orchestration for WAF config generators.

  Each provider implements three callbacks:
  - `yang_module/0` — returns the YANG source for this provider's config schema
  - `map_routes/2` — maps routes + config into a YANG instance data tree
  - `serialize/2` — converts a validated instance tree to the provider's native format

  The shared `generate/3` function orchestrates the pipeline:
  1. Parse and resolve the YANG module
  2. Call `map_routes/2` to build the instance tree
  3. Validate the instance against the YANG schema
  4. Call `serialize/2` to produce the output string

  Capability-shaped providers (e.g. MCP) implement `map_capabilities/2` instead of
  `map_routes/2` + `serialize/2`. `generate/3` dispatches on which callback is exported.

  Errors from any stage are wrapped in `Comn.Errors.ErrorStruct` with appropriate
  categories (`:validation` for schema violations, `:internal` for unexpected failures).
  """

  alias Wagger.Generator.Validator

  @doc "Returns the YANG source code for this provider's configuration schema."
  @callback yang_module() :: String.t()
  @doc "Maps application routes and configuration into a YANG instance data tree."
  @callback map_routes(routes :: [map()], config :: map()) :: map()
  @doc "Converts a validated instance tree to the provider's native configuration format."
  @callback serialize(instance :: map(), schema :: struct()) :: String.t()

  @doc "Alternative entry point for capability-shaped providers (e.g. MCP). Returns `{:ok, yang_text}` on success; the orchestrator encodes it and round-trip-validates. Returns `{:error, term()}` on any pipeline failure."
  @callback map_capabilities(capabilities :: map(), config :: map()) ::
              {:ok, ExYang.Model.Module.t()} | {:error, term()}

  @optional_callbacks map_capabilities: 2, map_routes: 2, serialize: 2

  @doc """
  Generates WAF configuration for the given provider module.

  Returns `{:ok, output_string}` on success or `{:error, reason}` on failure.
  """
  def generate(provider_module, input, config) do
    Code.ensure_loaded(provider_module)

    if function_exported?(provider_module, :map_capabilities, 2) do
      generate_capabilities(provider_module, input, config)
    else
      generate_routes(provider_module, input, config)
    end
  end

  defp generate_routes(provider_module, routes, config) do
    yang_source = provider_module.yang_module()

    with {:ok, parsed} <- ExYang.parse(yang_source),
         {:ok, resolved} <- ExYang.resolve(parsed, %{}),
         instance = provider_module.map_routes(routes, config),
         :ok <- Validator.validate(instance, resolved) do
      output = provider_module.serialize(instance, resolved)
      {:ok, output}
    else
      {:error, reasons} when is_list(reasons) ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/validation_failed",
           message: Enum.join(reasons, "; "),
           field: "instance"
         )}

      {:error, reason} when is_binary(reason) ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_parse_failed",
           message: reason
         )}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/yang_resolve_failed",
           message: inspect(reason)
         )}
    end
  end

  defp generate_capabilities(provider_module, capabilities, config) do
    canonical_source = provider_module.yang_module()

    with {:ok, canonical_parsed} <- parse_canonical(canonical_source),
         {:ok, canonical_resolved} <- resolve_canonical(canonical_parsed),
         {:ok, module_struct} <- provider_module.map_capabilities(capabilities, config),
         {:ok, yang_text} <- encode_module(module_struct),
         {:ok, reparsed} <- reparse(yang_text),
         {:ok, _} <- reresolve(reparsed, canonical_resolved) do
      {:ok, yang_text}
    else
      {:error, _} = err -> err
    end
  end

  defp parse_canonical(source) do
    case ExYang.parse(source) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/canonical_mcp_invalid",
           message: "parse failed: #{inspect(reason)}"
         )}
    end
  end

  defp resolve_canonical(parsed) do
    case ExYang.resolve(parsed, %{}) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/canonical_mcp_invalid",
           message: "resolve failed: #{inspect(reason)}"
         )}
    end
  end

  defp encode_module(module_struct) do
    ExYang.Encoder.Encoder.encode(module_struct)
  end

  defp reparse(yang_text) do
    case ExYang.parse(yang_text) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/mcp_roundtrip_failed",
           message: "reparse failed: #{inspect(reason)}"
         )}
    end
  end

  defp reresolve(parsed, canonical_resolved) do
    registry = %{canonical_resolved.module.name => canonical_resolved.module}

    case ExYang.resolve(parsed, registry) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, reason} ->
        {:error,
         Comn.Errors.Registry.error!("wagger.generator/mcp_roundtrip_failed",
           message: "reresolve failed: #{inspect(reason)}"
         )}
    end
  end
end
