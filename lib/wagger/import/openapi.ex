defmodule Wagger.Import.OpenApi do
  @moduledoc """
  Parses OpenAPI 3.x JSON specifications into route maps for import.

  Accepts either a decoded map or a raw JSON string. Extracts paths, HTTP
  methods, descriptions, query parameters, and header parameters from the
  OpenAPI `paths` object.
  """

  @http_methods ~w(get post put patch delete head options)

  @doc """
  Parses an OpenAPI 3.x spec into a list of route maps.

  Accepts either an already-decoded map or a JSON string.

  Returns `{routes, errors}` where `routes` is a list of maps with keys
  `:path`, `:methods`, `:path_type`, `:description`, `:query_params`,
  and `:headers`.

  ## Error cases

  - Invalid JSON string → `{[], ["Invalid JSON: <message>"]}`
  - Missing `"paths"` key → `{[], ["No paths found in OpenAPI spec"]}`

  ## Example

      iex> Wagger.Import.OpenApi.parse(%{"paths" => %{"/api/users" => %{"get" => %{"summary" => "List users"}}}})
      {[%{path: "/api/users", methods: ["GET"], path_type: "exact", description: "List users", query_params: [], headers: []}], []}

  """
  def parse(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, decoded} -> parse(decoded)
      {:error, %Jason.DecodeError{} = err} -> {[], ["Invalid JSON: #{Exception.message(err)}"]}
    end
  end

  def parse(spec) when is_map(spec) do
    case Map.fetch(spec, "paths") do
      :error -> {[], ["No paths found in OpenAPI spec"]}
      {:ok, paths} -> {parse_paths(paths), []}
    end
  end

  defp parse_paths(paths) do
    Enum.map(paths, fn {path, operations} ->
      build_route(path, operations)
    end)
  end

  defp build_route(path, operations) do
    methods = extract_methods(operations)
    description = extract_description(operations)
    {query_params, headers} = extract_parameters(operations)

    %{
      path: path,
      methods: methods,
      path_type: "exact",
      description: description,
      query_params: query_params,
      headers: headers
    }
  end

  defp extract_methods(operations) do
    @http_methods
    |> Enum.filter(&Map.has_key?(operations, &1))
    |> Enum.map(&String.upcase/1)
  end

  defp extract_description(operations) do
    @http_methods
    |> Enum.find_value(fn method ->
      case Map.get(operations, method) do
        nil -> nil
        op -> Map.get(op, "summary") || Map.get(op, "description")
      end
    end)
  end

  defp extract_parameters(operations) do
    all_params =
      @http_methods
      |> Enum.flat_map(fn method ->
        case Map.get(operations, method) do
          nil -> []
          op -> Map.get(op, "parameters", [])
        end
      end)

    query_params =
      all_params
      |> Enum.filter(&(&1["in"] == "query"))
      |> dedup_by_name()
      |> Enum.map(&%{"name" => &1["name"], "required" => &1["required"] || false})

    headers =
      all_params
      |> Enum.filter(&(&1["in"] == "header"))
      |> dedup_by_name()
      |> Enum.map(&%{"name" => &1["name"], "required" => &1["required"] || false})

    {query_params, headers}
  end

  defp dedup_by_name(params) do
    params
    |> Enum.uniq_by(& &1["name"])
  end
end
