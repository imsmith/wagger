defmodule Wagger.Generator.PathHelper do
  @moduledoc """
  Helper module for converting canonical route paths into provider-specific patterns.

  Supports converting paths with `{param}` placeholders into regex patterns,
  wildcard patterns (for AWS WAF), and nginx location directives.
  """

  @doc """
  Converts a canonical route to a regex pattern string.

  For exact paths, returns a fully anchored regex with start (^) and end ($) anchors.
  For prefix paths, returns a pattern with start anchor and trailing wildcard.
  For regex paths, returns the pattern unchanged.

  Replaces `{param}` placeholders with `[^/]+` to match any non-slash characters.

  ## Examples

      iex> Wagger.Generator.PathHelper.to_regex(%{path: "/api/users", path_type: "exact"})
      "^/api/users$"

      iex> Wagger.Generator.PathHelper.to_regex(%{path: "/api/users/{id}", path_type: "exact"})
      "^/api/users/[^/]+$"

      iex> Wagger.Generator.PathHelper.to_regex(%{path: "/static", path_type: "prefix"})
      "^/static.*"

      iex> Wagger.Generator.PathHelper.to_regex(%{path: "^/api/v[12]/.*", path_type: "regex"})
      "^/api/v[12]/.*"

  """
  def to_regex(%{path: path, path_type: "regex"}), do: path

  def to_regex(%{path: path, path_type: "exact"}) do
    converted = convert_params_to_regex(path)
    "^#{converted}$"
  end

  def to_regex(%{path: path, path_type: "prefix"}) do
    converted = convert_params_to_regex(path)
    "^#{converted}.*"
  end

  @doc """
  Converts a canonical route to a wildcard pattern (for AWS WAF).

  Replaces `{param}` placeholders with `*`.
  Prefix paths get a trailing `*` appended.

  ## Examples

      iex> Wagger.Generator.PathHelper.to_wildcard(%{path: "/api/users", path_type: "exact"})
      "/api/users"

      iex> Wagger.Generator.PathHelper.to_wildcard(%{path: "/api/users/{id}", path_type: "exact"})
      "/api/users/*"

      iex> Wagger.Generator.PathHelper.to_wildcard(%{path: "/static", path_type: "prefix"})
      "/static/*"

  """
  def to_wildcard(%{path: path, path_type: "exact"}) do
    convert_params_to_wildcard(path)
  end

  def to_wildcard(%{path: path, path_type: "prefix"}) do
    converted = convert_params_to_wildcard(path)
    # Ensure trailing slash before wildcard
    case String.ends_with?(converted, "/") do
      true -> converted <> "*"
      false -> converted <> "/*"
    end
  end

  @doc """
  Converts a canonical route to an nginx location directive.

  Returns a tuple `{type, pattern}` where type is one of:
  - `:exact` — for exact paths without parameters
  - `:regex` — for paths with parameters or regex patterns
  - `:prefix` — for prefix paths

  ## Examples

      iex> Wagger.Generator.PathHelper.to_nginx_location(%{path: "/api/users", path_type: "exact"})
      {:exact, "/api/users"}

      iex> Wagger.Generator.PathHelper.to_nginx_location(%{path: "/api/users/{id}", path_type: "exact"})
      {:regex, "^/api/users/[^/]+$"}

      iex> Wagger.Generator.PathHelper.to_nginx_location(%{path: "/static", path_type: "prefix"})
      {:prefix, "/static/"}

      iex> Wagger.Generator.PathHelper.to_nginx_location(%{path: "^/api/v[12]/.*", path_type: "regex"})
      {:regex, "^/api/v[12]/.*"}

  """
  def to_nginx_location(%{path: path, path_type: "exact"}) do
    case has_params?(path) do
      true -> {:regex, to_regex(%{path: path, path_type: "exact"})}
      false -> {:exact, path}
    end
  end

  def to_nginx_location(%{path: path, path_type: "prefix"}) do
    # Ensure trailing slash for prefix
    prefix =
      if String.ends_with?(path, "/") do
        path
      else
        path <> "/"
      end

    {:prefix, prefix}
  end

  def to_nginx_location(%{path: path, path_type: "regex"}) do
    {:regex, path}
  end

  @doc """
  Partitions routes by their effective method-set, using explode-then-cluster bucketing.

  The semantic key for grouping is `{method, path}`: two routes can map to the same
  key if they both declare the same method for the same path, even if they are
  separate route records. This function deduplicates and re-groups by path to
  reconstruct the full method-set for each path, then buckets paths by their
  effective method-set.

  ## Algorithm (4 steps)

  1. **Explode**: Each route's `methods` list is expanded into atomic `{method, route}`
     pairs. A route declaring `methods: ["GET", "POST"]` for `/a` produces two atoms.

  2. **Dedupe**: Atoms are deduplicated by `{method, path}`. If two distinct source
     routes both contribute `{GET, /a}`, only one survives.

  3. **Group by path**: Atoms are grouped by `route.path`, reconstructing the
     effective method-set for each path (sorted, unique union of all methods
     seen for that path).

  4. **Bucket by method-set**: Paths are then grouped by their reconstructed
     method-set, creating one bucket per distinct set. Each bucket is a list
     of mapped paths. Buckets are sorted by method-set for deterministic output.

  ## Arguments

  - `routes`: A list of route records (maps with `path` and `methods` keys).
    Each route's `methods` is a list of HTTP method strings.

  - `mapper`: A 1-arity function that projects a route record to the desired path
    representation. Called once per unique `path` with the first route record for
    that path, allowing callers to project paths as needed (e.g., as a regex,
    full route object, raw path string, etc.).

  ## Return value

  A list of `{sorted_methods, [mapped_path, ...]}` tuples, sorted by method-set.
  Each bucket contains all mapped paths sharing the same effective method-set.

  ## Examples

      iex> routes = [
      ...>   %{path: "/a", methods: ["GET", "POST"], path_type: "exact"},
      ...>   %{path: "/b", methods: ["GET"], path_type: "exact"}
      ...> ]
      iex> Wagger.Generator.PathHelper.partition_by_method_set(routes, & &1.path)
      [{["GET"], ["/b"]}, {["GET", "POST"], ["/a"]}]

  """
  def partition_by_method_set(routes, mapper) when is_function(mapper, 1) do
    routes
    |> Enum.flat_map(fn r -> Enum.map(r.methods, &{&1, r}) end)
    |> Enum.uniq_by(fn {m, r} -> {m, r.path} end)
    |> Enum.group_by(fn {_, r} -> r.path end)
    |> Enum.map(fn {_path, atoms} ->
      methods = atoms |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.uniq()
      route = atoms |> List.first() |> elem(1)
      {methods, mapper.(route)}
    end)
    |> Enum.group_by(fn {methods, _} -> methods end, fn {_, mapped} -> mapped end)
    |> Enum.sort_by(fn {methods, _} -> methods end)
  end

  # Helper functions

  defp convert_params_to_regex(path) do
    String.replace(path, ~r/\{[^}]+\}/, "[^/]+")
  end

  defp convert_params_to_wildcard(path) do
    String.replace(path, ~r/\{[^}]+\}/, "*")
  end

  defp has_params?(path) do
    String.contains?(path, "{")
  end
end
