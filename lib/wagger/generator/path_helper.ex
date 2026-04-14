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
