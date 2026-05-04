defmodule Wagger.Generator.Multi do
  @moduledoc """
  Sequences multiple generator modules and combines their outputs into a single
  annotated string.

  Each artifact is prefixed with a comment-style separator header identifying
  the filename and purpose. The combined string is stored as a single snapshot
  output value so drift detection covers all artifacts atomically.

  Usage:

      modules = [
        {"Cloud Armor", Wagger.Generator.Gcp, "gcp-armor.json"},
        {"URL Map", Wagger.Generator.GcpUrlMap, "gcp-urlmap.json"}
      ]
      {:ok, combined} = Wagger.Generator.Multi.generate(modules, routes, config)
  """

  alias Wagger.Generator

  @separator String.duplicate("=", 60)

  @doc """
  Generates output for each `{label, module, filename}` tuple in `specs`,
  runs them sequentially against `route_data` with `config`, and returns
  `{:ok, combined_string}` or `{:error, reason}` from the first failure.
  """
  @spec generate(
          specs :: [{label :: String.t(), module :: module(), filename :: String.t()}],
          route_data :: term(),
          config :: map()
        ) :: {:ok, String.t()} | {:error, term()}
  def generate(specs, route_data, config) do
    Enum.reduce_while(specs, {:ok, []}, fn {label, module, filename}, {:ok, acc} ->
      case Generator.generate(module, route_data, config) do
        {:ok, output} ->
          block = artifact_block(label, filename, output)
          {:cont, {:ok, [block | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, blocks} -> {:ok, Enum.join(Enum.reverse(blocks), "\n")}
      err -> err
    end
  end

  @doc """
  Splits a combined multi-artifact string back into `{label, filename, content}`
  tuples. Returns a single-element list with `{nil, nil, output}` when the
  input contains no separator headers (i.e., a legacy single-artifact snapshot).
  """
  @spec split_artifacts(combined :: String.t()) ::
          [{label :: String.t() | nil, filename :: String.t() | nil, content :: String.t()}]
  def split_artifacts(combined) when is_binary(combined) do
    # Match each artifact block: the three-line header followed by content.
    # Header pattern:
    #   // =====...
    #   // filename — label
    #   // =====...
    header_re = ~r|// ={20,}\n// (.+) — (.+)\n// ={20,}\n|

    case Regex.scan(header_re, combined, return: :index) do
      [] ->
        [{nil, nil, combined}]

      matches ->
        # Build a list of {start_of_header, end_of_header, filename, label} tuples.
        headers =
          Enum.map(matches, fn [{start, len} | _captures] ->
            [_full, {fn_start, fn_len}, {lbl_start, lbl_len}] =
              Regex.scan(header_re, binary_part(combined, start, byte_size(combined) - start),
                return: :index
              )
              |> hd()

            filename = binary_part(combined, start + fn_start, fn_len)
            label = binary_part(combined, start + lbl_start, lbl_len)
            {start, start + len, filename, label}
          end)

        # For each header, extract content as the slice from end-of-header to
        # start of the next header (or end of string).
        headers
        |> Enum.with_index()
        |> Enum.map(fn {{_hdr_start, content_start, filename, label}, idx} ->
          next_hdr_start =
            case Enum.at(headers, idx + 1) do
              nil -> byte_size(combined)
              {ns, _ne, _fn, _lbl} -> ns
            end

          content =
            combined
            |> binary_part(content_start, next_hdr_start - content_start)
            |> String.trim_trailing()

          {label, filename, content}
        end)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp artifact_block(label, filename, output) do
    trimmed = String.trim_trailing(output)
    "// #{@separator}\n// #{filename} — #{label}\n// #{@separator}\n#{trimmed}"
  end
end
