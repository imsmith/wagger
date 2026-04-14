defmodule Wagger.Export do
  @moduledoc """
  Converts application routes to EDN format for export.

  Produces a canonical EDN document containing all routes for a given
  application, with hyphenated keywords and typed values matching the
  Wagger schema conventions.
  """

  alias Wagger.Routes

  @version "1.0"

  @doc """
  Exports all routes for the given application as an EDN string.

  Returns `{:ok, edn_string}` where `edn_string` is a canonical EDN map
  with `:version`, `:exported`, and `:routes` keys.

  ## Example

      iex> Wagger.Export.to_edn(app)
      {:ok, "{:version \\"1.0\\" :exported \\"2026-04-13T14:30:00.000Z\\" :routes [...]}"}

  """
  def to_edn(app) do
    routes = Routes.list_routes(app)
    exported = utc_now_iso8601()

    edn =
      "{:version #{encode_string(@version)}" <>
        " :exported #{encode_string(exported)}" <>
        " :routes #{encode_routes(routes)}}"

    {:ok, edn}
  end

  defp utc_now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp encode_routes([]), do: "[]"

  defp encode_routes(routes) do
    inner =
      routes
      |> Enum.map(&encode_route/1)
      |> Enum.join(" ")

    "[#{inner}]"
  end

  defp encode_route(route) do
    parts = [
      ":path #{encode_string(route.path)}",
      ":methods #{encode_keyword_list(route.methods)}",
      ":path-type #{encode_keyword(route.path_type)}",
      ":description #{encode_string_or_nil(route.description)}",
      ":query-params #{encode_map_list(route.query_params)}",
      ":headers #{encode_map_list(route.headers)}",
      ":rate-limit #{encode_integer_or_nil(route.rate_limit)}",
      ":tags #{encode_keyword_list(route.tags)}"
    ]

    "{#{Enum.join(parts, " ")}}"
  end

  defp encode_string(s) when is_binary(s), do: ~s("#{escape_string(s)}")
  defp encode_string(nil), do: "nil"

  defp encode_string_or_nil(nil), do: "nil"
  defp encode_string_or_nil(s), do: encode_string(s)

  defp encode_integer_or_nil(nil), do: "nil"
  defp encode_integer_or_nil(n) when is_integer(n), do: Integer.to_string(n)

  defp encode_keyword(nil), do: "nil"
  defp encode_keyword(s) when is_binary(s), do: ":#{s}"

  defp encode_keyword_list(nil), do: "[]"
  defp encode_keyword_list([]), do: "[]"

  defp encode_keyword_list(items) when is_list(items) do
    inner =
      items
      |> Enum.map(fn item -> ":#{item}" end)
      |> Enum.join(" ")

    "[#{inner}]"
  end

  defp encode_map_list(nil), do: "[]"
  defp encode_map_list([]), do: "[]"

  defp encode_map_list(items) when is_list(items) do
    inner =
      items
      |> Enum.map(&encode_param_map/1)
      |> Enum.join(" ")

    "[#{inner}]"
  end

  defp encode_param_map(map) when is_map(map) do
    parts =
      map
      |> Enum.map(fn {k, v} -> "#{encode_keyword(to_string(k))} #{encode_param_value(v)}" end)
      |> Enum.join(" ")

    "{#{parts}}"
  end

  defp encode_param_value(true), do: "true"
  defp encode_param_value(false), do: "false"
  defp encode_param_value(nil), do: "nil"
  defp encode_param_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_param_value(v) when is_binary(v), do: encode_string(v)

  defp escape_string(s), do: String.replace(s, "\"", "\\\"")
end
