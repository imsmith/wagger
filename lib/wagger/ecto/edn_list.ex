defmodule Wagger.Ecto.EdnList do
  @moduledoc """
  Custom Ecto type for storing a list of keywords/strings as EDN text in SQLite.

  Accepts a list of strings or atoms, serializes as an EDN vector of keywords
  (e.g. `[:GET :POST]`), and deserializes back to a list of strings.

  Suitable for fields like HTTP methods and tags.
  """

  use Ecto.Type

  @impl true
  def type, do: :string

  @impl true
  def cast(list) when is_list(list) do
    normalized =
      Enum.reduce_while(list, [], fn
        item, acc when is_binary(item) -> {:cont, acc ++ [item]}
        item, acc when is_atom(item) -> {:cont, acc ++ [Atom.to_string(item)]}
        _item, _acc -> {:halt, :error}
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
    keywords = Enum.map_join(list, " ", fn item -> ":#{item}" end)
    {:ok, "[#{keywords}]"}
  end

  def dump(_), do: :error

  @impl true
  def load(nil), do: {:ok, []}

  def load(edn) when is_binary(edn) do
    case Eden.decode(edn) do
      {:ok, array} ->
        items =
          array
          |> Array.to_list()
          |> Enum.map(fn
            atom when is_atom(atom) -> Atom.to_string(atom)
            str when is_binary(str) -> str
          end)

        {:ok, items}

      {:error, _} ->
        :error
    end
  end

  def load(_), do: :error
end
