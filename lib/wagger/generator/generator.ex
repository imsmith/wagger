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

  @doc """
  Generates WAF configuration for the given provider module.

  Returns `{:ok, output_string}` on success or `{:error, reason}` on failure.
  """
  def generate(provider_module, routes, config) do
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
end
