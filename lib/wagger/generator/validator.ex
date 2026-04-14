defmodule Wagger.Generator.Validator do
  @moduledoc """
  Validates Elixir maps (YANG instance data) against resolved YANG schemas.

  Takes a nested map with string keys and a `ExYang.Resolver.ResolvedModule`
  and returns `:ok` or `{:error, [error_strings]}` where each string names
  the offending path and what went wrong.
  """

  alias ExYang.Model.Container
  alias ExYang.Model.Leaf
  alias ExYang.Model.LeafList
  # ExYang.Model.List is aliased explicitly to avoid shadowing Elixir.List
  alias ExYang.Model.List, as: YangList

  @integer_types ~w[
    int8 int16 int32 int64
    uint8 uint16 uint32 uint64
  ]

  @doc """
  Validate `data` against the top-level data definitions in `resolved_module`.

  Returns `:ok` when valid, `{:error, [String.t()]}` listing every violation.
  """
  @spec validate(map(), ExYang.Resolver.ResolvedModule.t()) :: :ok | {:error, [String.t()]}
  def validate(data, resolved_module) when is_map(data) do
    schema_nodes = resolved_module.module.body
    errors = validate_body(data, schema_nodes, "")

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp validate_body(data, schema_nodes, path) do
    schema_names = MapSet.new(schema_nodes, & &1.name)
    data_keys = Map.keys(data)

    unknown_errors =
      data_keys
      |> Enum.reject(&MapSet.member?(schema_names, &1))
      |> Enum.map(&"#{path}/#{&1}: unknown key")

    node_errors =
      Enum.flat_map(schema_nodes, fn node ->
        validate_node(data, node, path)
      end)

    unknown_errors ++ node_errors
  end

  defp validate_node(data, %Leaf{} = leaf, path) do
    node_path = "#{path}/#{leaf.name}"
    value = Map.get(data, leaf.name)

    cond do
      is_nil(value) && leaf.mandatory == true ->
        ["#{node_path}: mandatory leaf missing"]

      is_nil(value) ->
        []

      true ->
        validate_type(value, leaf.type, node_path)
    end
  end

  defp validate_node(data, %LeafList{} = ll, path) do
    node_path = "#{path}/#{ll.name}"
    value = Map.get(data, ll.name)

    cond do
      is_nil(value) ->
        []

      not is_list(value) ->
        ["#{node_path}: expected a list"]

      true ->
        value
        |> Enum.with_index()
        |> Enum.flat_map(fn {item, idx} ->
          validate_type(item, ll.type, "#{node_path}[#{idx}]")
        end)
    end
  end

  defp validate_node(data, %YangList{} = list_node, path) do
    node_path = "#{path}/#{list_node.name}"
    value = Map.get(data, list_node.name)

    cond do
      is_nil(value) ->
        []

      not is_list(value) ->
        ["#{node_path}: expected a list of maps"]

      true ->
        key_names = parse_key(list_node.key)

        key_errors =
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {entry, idx} ->
            entry_path = "#{node_path}[#{idx}]"

            key_names
            |> Enum.flat_map(fn k ->
              if Map.has_key?(entry, k),
                do: [],
                else: ["#{entry_path}/#{k}: list key leaf missing"]
            end)
          end)

        duplicate_errors = find_duplicate_keys(value, key_names, node_path)

        child_errors =
          value
          |> Enum.with_index()
          |> Enum.flat_map(fn {entry, idx} ->
            validate_body(entry, list_node.body, "#{node_path}[#{idx}]")
          end)

        key_errors ++ duplicate_errors ++ child_errors
    end
  end

  defp validate_node(data, %Container{} = container, path) do
    node_path = "#{path}/#{container.name}"
    value = Map.get(data, container.name)

    cond do
      is_nil(value) ->
        []

      not is_map(value) ->
        ["#{node_path}: expected a map"]

      true ->
        validate_body(value, container.body, node_path)
    end
  end

  # Ignore node types we don't validate (Choice, Case, AnyData, etc.)
  defp validate_node(_data, _node, _path), do: []

  # ---------------------------------------------------------------------------
  # Type validation
  # ---------------------------------------------------------------------------

  defp validate_type(_value, nil, _path), do: []

  defp validate_type(value, type, path) do
    type_name = type.name
    enum_values = type.enum_values

    type_errors = check_base_type(value, type_name, path)

    enum_errors =
      if type_name == "enumeration" && not is_nil(value) && enum_values != [] do
        valid_names = MapSet.new(enum_values, & &1.name)

        if MapSet.member?(valid_names, value),
          do: [],
          else: ["#{path}: invalid enum value #{inspect(value)}, expected one of #{inspect(MapSet.to_list(valid_names))}"]
      else
        []
      end

    type_errors ++ enum_errors
  end

  defp check_base_type(value, type_name, path) when type_name in @integer_types do
    if is_integer(value),
      do: [],
      else: ["#{path}: expected integer for type #{type_name}, got #{inspect(value)}"]
  end

  defp check_base_type(value, "string", path) do
    if is_binary(value),
      do: [],
      else: ["#{path}: expected string, got #{inspect(value)}"]
  end

  defp check_base_type(value, "boolean", path) do
    if is_boolean(value),
      do: [],
      else: ["#{path}: expected boolean, got #{inspect(value)}"]
  end

  defp check_base_type(value, "enumeration", path) do
    if is_binary(value),
      do: [],
      else: ["#{path}: expected string for enumeration, got #{inspect(value)}"]
  end

  defp check_base_type(_value, _type_name, _path), do: []

  # ---------------------------------------------------------------------------
  # Utility
  # ---------------------------------------------------------------------------

  defp parse_key(nil), do: []
  defp parse_key(key_str), do: String.split(key_str, " ", trim: true)

  defp find_duplicate_keys(entries, key_names, path) do
    entries
    |> Enum.map(fn entry ->
      Enum.map(key_names, &Map.get(entry, &1))
    end)
    |> Enum.with_index()
    |> Enum.group_by(fn {combo, _idx} -> combo end)
    |> Enum.flat_map(fn {_combo, occurrences} ->
      if length(occurrences) > 1 do
        indices = Enum.map(occurrences, fn {_combo, idx} -> idx end)
        ["#{path}: duplicate list key combination at entries #{inspect(indices)}"]
      else
        []
      end
    end)
  end
end
