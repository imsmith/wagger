defmodule Wagger.Import.Bulk do
  @moduledoc """
  Parses bulk text route definitions into route maps.

  Input format: one route per line, `METHOD /path - description`.
  Methods are comma-separated and case-insensitive. Omitting the method
  defaults to GET. Lines starting with `#` and blank lines are skipped.
  Unparseable lines are collected as `"line N: original text"` in the
  second element of the returned tuple.

  Express-style `:param` segments are normalized to `{param}`. Paths
  ending with `/` (except the root `/`) get `path_type: "prefix"`;
  everything else gets `path_type: "exact"`.
  """

  @doc """
  Parses a multi-line string of route definitions.

  Returns `{routes, skipped}` where each route is a map with keys
  `:path`, `:methods`, `:path_type`, and `:description`.
  """
  @spec parse(String.t()) :: {[map()], [String.t()]}
  def parse(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _n} -> skip?(line) end)
    |> Enum.reduce({[], []}, fn {line, n}, {routes, skipped} ->
      case parse_line(line) do
        {:ok, route} -> {[route | routes], skipped}
        :error -> {routes, [skipped_entry(n, line) | skipped]}
      end
    end)
    |> then(fn {routes, skipped} -> {Enum.reverse(routes), Enum.reverse(skipped)} end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp skip?(line) do
    trimmed = String.trim(line)
    trimmed == "" or String.starts_with?(trimmed, "#")
  end

  # METHOD[,METHOD...] /path[ - description]
  @method_chars ~r/^([A-Za-z,]+)\s+(\/\S*)\s*(?:-\s*(.+))?$/
  # /path[ - description]  (no method prefix)
  @path_only ~r/^(\/\S*)\s*(?:-\s*(.+))?$/

  defp parse_line(line) do
    trimmed = String.trim(line)

    cond do
      Regex.match?(@method_chars, trimmed) ->
        captures = Regex.run(@method_chars, trimmed, capture: :all)
        {methods_raw, path_raw, desc_raw} = extract_method_captures(captures)
        {:ok, build_route(methods_raw, path_raw, nilify(desc_raw))}

      Regex.match?(@path_only, trimmed) ->
        captures = Regex.run(@path_only, trimmed, capture: :all)
        {path_raw, desc_raw} = extract_path_captures(captures)
        {:ok, build_route(nil, path_raw, nilify(desc_raw))}

      true ->
        :error
    end
  end

  defp extract_method_captures([_, methods, path]), do: {methods, path, nil}
  defp extract_method_captures([_, methods, path, desc]), do: {methods, path, desc}

  defp extract_path_captures([_, path]), do: {path, nil}
  defp extract_path_captures([_, path, desc]), do: {path, desc}

  defp build_route(methods_raw, path_raw, description) do
    methods = parse_methods(methods_raw)
    path = normalize_path(path_raw)
    path_type = infer_path_type(path_raw)

    %{
      path: path,
      methods: methods,
      path_type: path_type,
      description: description
    }
  end

  defp parse_methods(nil), do: ["GET"]

  defp parse_methods(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&(String.trim(&1) |> String.upcase()))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_path(path) do
    Regex.replace(~r/:([A-Za-z_][A-Za-z0-9_]*)/, path, "{\\1}")
  end

  defp infer_path_type("/"), do: "exact"
  defp infer_path_type(path), do: if(String.ends_with?(path, "/"), do: "prefix", else: "exact")

  defp nilify(nil), do: nil
  defp nilify(""), do: nil
  defp nilify(str), do: String.trim(str)

  defp skipped_entry(n, line), do: "line #{n}: #{String.trim(line)}"
end
