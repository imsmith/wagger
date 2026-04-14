defmodule Wagger.Import.AccessLog do
  @moduledoc """
  Parses web server access logs into route maps.

  Supports nginx/Apache combined and common formats, Caddy JSON, and AWS ALB
  logs (which share the nginx quoted-request pattern). Auto-detects format
  per line.

  Paths are stripped of query strings. Requests to the same path are grouped
  together, accumulating distinct methods and a total count. Routes are
  returned sorted by request count descending.
  """

  # Matches the quoted request field in nginx/Apache combined/common format:
  # "METHOD /path HTTP/x.x"
  @nginx_re ~r/"([A-Z]+) ([^\s"]+) HTTP\/[\d.]+"/

  @doc """
  Parses a string of access log lines into `{routes, skipped}`.

  Each element of `routes` is a map with keys `:path`, `:methods`,
  `:path_type`, and `:description`. Unparseable non-blank lines are collected
  in `skipped` as `"line N: <first 80 chars>"`.
  """
  def parse(input) when is_binary(input) do
    lines = String.split(input, "\n", trim: true)

    {acc, skipped} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, []}, fn {line, lineno}, {acc, skipped} ->
        trimmed = String.trim(line)

        cond do
          trimmed == "" ->
            {acc, skipped}

          String.starts_with?(trimmed, "{") ->
            case parse_caddy_json(trimmed) do
              {:ok, method, path} -> {accumulate(acc, path, method), skipped}
              :error -> {acc, [format_skip(lineno, trimmed) | skipped]}
            end

          true ->
            case parse_nginx(trimmed) do
              {:ok, method, path} -> {accumulate(acc, path, method), skipped}
              :error -> {acc, [format_skip(lineno, trimmed) | skipped]}
            end
        end
      end)

    routes =
      acc
      |> Enum.map(fn {path, %{methods: methods, count: count}} ->
        %{
          path: path,
          methods: Enum.sort(MapSet.to_list(methods)),
          path_type: "exact",
          description: "#{count} request(s) observed"
        }
      end)
      |> Enum.sort_by(fn %{description: d} ->
        {count, _} = Integer.parse(d)
        -count
      end)

    {routes, Enum.reverse(skipped)}
  end

  defp parse_nginx(line) do
    case Regex.run(@nginx_re, line) do
      [_full, method, raw_path] ->
        {:ok, method, strip_query(raw_path)}

      nil ->
        :error
    end
  end

  defp parse_caddy_json(line) do
    with {:ok, decoded} <- Jason.decode(line),
         %{"request" => %{"method" => method, "uri" => uri}} <- decoded do
      {:ok, method, strip_query(uri)}
    else
      _ -> :error
    end
  end

  defp strip_query(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
  end

  defp accumulate(acc, path, method) do
    Map.update(
      acc,
      path,
      %{methods: MapSet.new([method]), count: 1},
      fn entry ->
        %{entry | methods: MapSet.put(entry.methods, method), count: entry.count + 1}
      end
    )
  end

  defp format_skip(lineno, line) do
    "line #{lineno}: #{String.slice(line, 0, 80)}"
  end
end
