defmodule Wagger.Generator.Mcp.Builder do
  @moduledoc """
  Pure functions that turn a capability map into `ExYang.Model.*` structs.

  Validation and struct construction only. No I/O, no encoding, no parsing.
  """

  @yang_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_\-\.]*\z/

  @doc """
  Validates a capability map. Returns `:ok` or a structured error tuple.

  Errors take the form:
  - `{:missing, path}` — required field absent
  - `{:invalid_identifier, path, value}` — field is not a valid YANG identifier
  - `{:duplicate, collection, name}` — duplicate primitive name
  """
  def validate(%{} = caps) do
    with :ok <- require_key(caps, :app_name),
         :ok <- valid_identifier(caps, :app_name),
         :ok <- validate_tools(Map.get(caps, :tools, [])),
         :ok <- validate_resources(Map.get(caps, :resources, [])),
         :ok <- validate_prompts(Map.get(caps, :prompts, [])) do
      :ok
    end
  end

  defp require_key(caps, key) do
    if Map.has_key?(caps, key), do: :ok, else: {:error, {:missing, to_string(key)}}
  end

  defp valid_identifier(caps, key) do
    value = Map.fetch!(caps, key)

    if Regex.match?(@yang_identifier, value) do
      :ok
    else
      {:error, {:invalid_identifier, to_string(key), value}}
    end
  end

  defp validate_tools(tools) do
    with :ok <- require_field_in_list(tools, :name, "tools"),
         :ok <- no_duplicates(tools, :name, "tools") do
      :ok
    end
  end

  defp validate_resources(resources) do
    with :ok <- require_field_in_list(resources, :uri_template, "resources"),
         :ok <- no_duplicates(resources, :uri_template, "resources") do
      :ok
    end
  end

  defp validate_prompts(prompts) do
    with :ok <- require_field_in_list(prompts, :name, "prompts"),
         :ok <- no_duplicates(prompts, :name, "prompts") do
      :ok
    end
  end

  defp require_field_in_list(list, field, collection) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {entry, idx}, :ok ->
      if Map.has_key?(entry, field) do
        {:cont, :ok}
      else
        {:halt, {:error, {:missing, "#{collection}[#{idx}].#{field}"}}}
      end
    end)
  end

  defp no_duplicates(list, field, collection) do
    names = Enum.map(list, &Map.fetch!(&1, field))
    dup = names -- Enum.uniq(names)

    case dup do
      [] -> :ok
      [name | _] -> {:error, {:duplicate, collection, name}}
    end
  end
end
