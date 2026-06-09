defmodule Wagger.Generator.SecRule do
  @moduledoc """
  Shared ModSecurity SecRule construction and rendering, used by both the
  Coraza and Apache generators. Pure functions — no `Wagger.Generator`
  behaviour. The rule bodies produced here are byte-for-byte identical
  between Coraza (standalone engine) and Apache (`mod_security2`); only the
  surrounding packaging differs per provider.
  """

  @default_start_rule_id 100_001
  @catch_all_offset 90_000

  @doc "Default first rule ID when config supplies none."
  def default_start_rule_id, do: @default_start_rule_id

  @doc "Offset added to the start rule ID to derive the catch-all rule ID."
  def catch_all_offset, do: @catch_all_offset

  @doc """
  Builds the per-route rule list plus the start/catch-all IDs from routes and
  config. Returns `%{rules: [...], start_id: integer, catch_all_id: integer}`.
  Each rule is a string-keyed map: `id`, `path-pattern`, `methods`, optional
  `description`, optional `rate-limit-comment`.
  """
  def build_rules(routes, config) do
    start_id = parse_int(config, "start_rule_id", @default_start_rule_id)

    rules =
      routes
      |> Enum.with_index()
      |> Enum.map(fn {route, idx} -> build_rule(route, start_id + idx) end)

    %{rules: rules, start_id: start_id, catch_all_id: start_id + @catch_all_offset}
  end

  defp build_rule(route, id) do
    r = normalize(route)
    pattern = Wagger.Generator.PathHelper.to_regex(r)

    base = %{
      "id" => id,
      "path-pattern" => pattern,
      "methods" => r.methods
    }

    base =
      if r.description do
        Map.put(base, "description", r.description)
      else
        base
      end

    if r.rate_limit do
      Map.put(base, "rate-limit-comment", "#{r.rate_limit} req/min (enforce at proxy layer)")
    else
      base
    end
  end

  @doc "Renders all per-route SecRule blocks, newline-joined."
  def render_rules(rules) do
    Enum.map_join(rules, "\n", &render_rule/1)
  end

  @doc "Renders a single chained allow SecRule block."
  def render_rule(rule) do
    id = rule["id"]
    pattern = rule["path-pattern"]
    methods = rule["methods"]
    description = Map.get(rule, "description")
    rate_comment = Map.get(rule, "rate-limit-comment")

    methods_str = Enum.join(methods, " ")

    comment =
      if description do
        "# #{methods_str} #{original_path_from_pattern(pattern)} — #{description}"
      else
        "# #{methods_str} #{original_path_from_pattern(pattern)}"
      end

    rate_line =
      if rate_comment do
        "\n# Rate limit: #{rate_comment}"
      else
        ""
      end

    """
    #{comment}#{rate_line}
    SecRule REQUEST_URI "@rx #{pattern}" "id:#{id},phase:1,chain,allow"
      SecRule REQUEST_METHOD "@pm #{methods_str}" "t:none"
    """
  end

  @doc "Renders the final catch-all deny block for undeclared paths."
  def render_catch_all(id, phase, status) do
    """
    # Deny all undeclared paths
    SecRule REQUEST_URI "@rx .*" "id:#{id},phase:#{phase},deny,status:#{status},msg:'No matching route'"
    """
  end

  @doc false
  def normalize(route) do
    %{
      path: route[:path] || route["path"],
      path_type: route[:path_type] || route["path_type"],
      methods: route[:methods] || route["methods"],
      rate_limit: route[:rate_limit] || route["rate_limit"],
      description: route[:description] || route["description"]
    }
  end

  @doc false
  def original_path_from_pattern(pattern) do
    pattern
    |> String.replace_prefix("^", "")
    |> String.replace_suffix("$", "")
    |> String.replace_suffix(".*", "/")
  end

  @doc false
  def iso8601_now do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  @doc false
  def parse_int(config, key, default) do
    val = config[String.to_atom(key)] || config[key]

    case val do
      nil -> default
      v when is_integer(v) -> v
      v when is_binary(v) -> String.to_integer(v)
    end
  end
end
