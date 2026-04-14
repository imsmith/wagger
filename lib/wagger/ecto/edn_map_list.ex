defmodule Wagger.Ecto.EdnMapList do
  @moduledoc """
  Custom Ecto type for storing a list of maps as EDN text in SQLite.

  Accepts a list of maps (string or atom keys), serializes as an EDN vector
  of maps with keyword keys (e.g. `[{:name "page" :required false}]`),
  and deserializes back to a list of maps with string keys.

  Suitable for fields like query_params and headers where each entry is a
  structured record.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list) do
    normalized =
      Enum.reduce_while(list, [], fn
        item, acc when is_map(item) ->
          string_keyed =
            Map.new(item, fn
              {k, v} when is_atom(k) -> {Atom.to_string(k), v}
              {k, v} when is_binary(k) -> {k, v}
            end)

          {:cont, acc ++ [string_keyed]}

        _item, _acc ->
          {:halt, :error}
      end)

    case normalized do
      :error -> :error
      result -> {:ok, result}
    end
  end

  def cast(_), do: :error

  @impl true
  def dump([]), do: {:ok, "[]"}

  def dump(list) when is_list(list) do
    maps_edn =
      Enum.map_join(list, " ", fn map ->
        pairs =
          Enum.map_join(map, " ", fn {k, v} ->
            ":#{k} #{encode_value(v)}"
          end)

        "{#{pairs}}"
      end)

    {:ok, "[#{maps_edn}]"}
  end

  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(edn) when is_binary(edn) do
    case Eden.decode(edn) do
      {:ok, array} ->
        maps =
          array
          |> Array.to_list()
          |> Enum.map(&decode_map/1)

        {:ok, maps}

      {:error, _} ->
        :error
    end
  end

  def load(_), do: :error

  # Encodes an Elixir value to an EDN string fragment.
  defp encode_value(nil), do: "nil"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_value(v) when is_float(v), do: Float.to_string(v)

  defp encode_value(v) when is_binary(v) do
    escaped = String.replace(v, "\"", "\\\"")
    "\"#{escaped}\""
  end

  # Converts an eden-decoded map (atom keys) to a string-keyed Elixir map.
  # Eden decodes EDN maps with keyword keys as atom keys.
  defp decode_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), decode_value(v)}
      {k, v} when is_binary(k) -> {k, decode_value(v)}
    end)
  end

  # Converts eden-decoded values to typed Elixir values.
  defp decode_value(nil), do: nil
  defp decode_value(true), do: true
  defp decode_value(false), do: false
  defp decode_value(v) when is_integer(v), do: v
  defp decode_value(v) when is_float(v), do: v
  defp decode_value(v) when is_binary(v), do: v
  defp decode_value(v) when is_atom(v), do: Atom.to_string(v)
end
