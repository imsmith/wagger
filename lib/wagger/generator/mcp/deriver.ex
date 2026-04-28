defmodule Wagger.Generator.Mcp.Deriver do
  @moduledoc """
  Walks an annotated `ExYang.Model.Module{}` and produces a capability map
  consumable by `Wagger.Generator.Mcp.Builder.build_module/2`, plus a
  derivation report describing what was emitted, warnings, and excluded nodes.

  Default-on policy: every `rpc`, every keyed `list`, and every top-level
  `container` is exposed unless tagged with `wagger-mcp:exclude`. See
  the design doc at `docs/superpowers/specs/2026-04-27-wagger-mcp-annotation-pipeline-design.md`.
  """

  @prefix "wagger-mcp"

  @doc "Convert kebab-case identifier to snake_case."
  def kebab_to_snake(name) when is_binary(name), do: String.replace(name, "-", "_")

  @doc "Return the argument of the named wagger-mcp extension if present, else nil."
  def extension_arg(extensions, name) when is_list(extensions) and is_binary(name) do
    Enum.find_value(extensions, fn
      %ExYang.Model.ExtensionUse{keyword: {@prefix, ^name}, argument: arg} -> arg
      _ -> nil
    end)
  end

  @doc "Returns true if the named wagger-mcp flag extension is present."
  def extension_present?(extensions, name) when is_list(extensions) and is_binary(name) do
    Enum.any?(extensions, fn
      %ExYang.Model.ExtensionUse{keyword: {@prefix, ^name}} -> true
      _ -> false
    end)
  end

  @doc """
  Returns `{tools, warnings}` for the given list of `%ExYang.Model.Rpc{}` nodes.
  Excludes rpcs flagged with `wagger-mcp:exclude` or `wagger-mcp:prompt-name`.
  """
  def derive_tools(rpcs) when is_list(rpcs) do
    rpcs
    |> Enum.reduce({[], []}, fn rpc, {tools, warns} ->
      cond do
        extension_present?(rpc.extensions, "exclude") ->
          {tools, warns}

        extension_arg(rpc.extensions, "prompt-name") != nil ->
          {tools, warns}

        true ->
          {tool, warns_for_tool} = build_tool(rpc)
          {[tool | tools], warns ++ warns_for_tool}
      end
    end)
    |> then(fn {tools, warns} -> {Enum.reverse(tools), warns} end)
  end

  defp build_tool(%ExYang.Model.Rpc{} = rpc) do
    name = extension_arg(rpc.extensions, "tool-name") || kebab_to_snake(rpc.name)

    llm_arg = extension_arg(rpc.extensions, "description-for-llm")

    {description, warns} =
      cond do
        not blank?(llm_arg) ->
          {llm_arg, []}

        not blank?(rpc.description) ->
          {rpc.description, []}

        true ->
          {rpc.name,
           [
             %{
               node: "/rpcs/#{rpc.name}",
               kind: :description_fallback,
               message: "no description-for-llm or YANG description; using identifier"
             }
           ]}
      end

    tool = %{
      name: name,
      description: description,
      input_schema: %{"type" => "object"},
      output_schema: %{"type" => "object"},
      dangerous: extension_present?(rpc.extensions, "dangerous"),
      read_only: extension_present?(rpc.extensions, "read-only")
    }

    {tool, warns}
  end

  @doc """
  Returns `{resources, issues}` where issues is a list of warning OR error maps.
  Errors carry `kind: :missing_key | :uri_template_missing_var`. Warnings carry
  `kind: :mime_type_default | :description_fallback`.
  """
  def derive_resources(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce({[], []}, fn node, {acc, issues} ->
      cond do
        excluded?(node) ->
          {acc, issues}

        true ->
          case build_resource(node) do
            {:ok, res, warns} -> {[res | acc], issues ++ warns}
            {:error, err} -> {acc, issues ++ [err]}
          end
      end
    end)
    |> then(fn {acc, issues} -> {Enum.reverse(acc), issues} end)
  end

  defp excluded?(%{body: body}) when is_list(body), do: extension_present?(body, "exclude")
  defp excluded?(_), do: false

  defp body_extensions(%{body: body}) when is_list(body) do
    Enum.filter(body, &match?(%ExYang.Model.ExtensionUse{keyword: {@prefix, _}}, &1))
  end

  defp body_extensions(_), do: []

  defp build_resource(%ExYang.Model.List{name: name, key: nil}) do
    {:error,
     %{
       node: "/lists/#{name}",
       kind: :missing_key,
       message: "list has no key; cannot auto-derive URI template"
     }}
  end

  defp build_resource(%ExYang.Model.List{name: name, key: key} = list) do
    exts = body_extensions(list)

    case extension_arg(exts, "resource-template") do
      nil ->
        finalize_resource(list, "#{name}://{#{key}}", exts, "/lists/#{name}")

      explicit ->
        if String.contains?(explicit, "{") and String.contains?(explicit, "}") do
          finalize_resource(list, explicit, exts, "/lists/#{name}")
        else
          {:error,
           %{
             node: "/lists/#{name}",
             kind: :uri_template_missing_var,
             message: "resource-template must contain at least one {var} for keyed list"
           }}
        end
    end
  end

  defp build_resource(%ExYang.Model.Container{name: name} = container) do
    exts = body_extensions(container)

    template =
      case extension_arg(exts, "resource-template") do
        nil -> "#{name}://"
        explicit -> explicit
      end

    finalize_resource(container, template, exts, "/containers/#{name}")
  end

  defp finalize_resource(node, template, exts, path) do
    {mime, mime_warns} = mime_type_for(exts, path)

    {:ok,
     %{
       uri_template: template,
       name: node.name,
       mime_type: mime,
       description: node.description || node.name
     }, mime_warns}
  end

  defp mime_type_for(exts, path) do
    case extension_arg(exts, "mime-type") do
      nil ->
        {"application/json",
         [
           %{
             node: path,
             kind: :mime_type_default,
             message: "no mime-type set; defaulting to application/json"
           }
         ]}

      mime ->
        {mime, []}
    end
  end

  @doc """
  Returns `{prompts, warnings}`. Only rpcs with `wagger-mcp:prompt-name` are
  prompts; exclude takes precedence.
  """
  def derive_prompts(rpcs) when is_list(rpcs) do
    rpcs
    |> Enum.reduce({[], []}, fn rpc, {acc, warns} ->
      cond do
        extension_present?(rpc.extensions, "exclude") ->
          {acc, warns}

        extension_arg(rpc.extensions, "prompt-name") == nil ->
          {acc, warns}

        true ->
          {prompt, w} = build_prompt(rpc)
          {[prompt | acc], warns ++ w}
      end
    end)
    |> then(fn {acc, warns} -> {Enum.reverse(acc), warns} end)
  end

  defp build_prompt(%ExYang.Model.Rpc{} = rpc) do
    name = extension_arg(rpc.extensions, "prompt-name")

    llm_arg = extension_arg(rpc.extensions, "description-for-llm")

    {description, warns} =
      cond do
        not blank?(llm_arg) ->
          {llm_arg, []}

        not blank?(rpc.description) ->
          {rpc.description, []}

        true ->
          {rpc.name,
           [
             %{
               node: "/rpcs/#{rpc.name}",
               kind: :description_fallback,
               message: "no description; using identifier"
             }
           ]}
      end

    {%{name: name, description: description, arguments: []}, warns}
  end

  @doc """
  Walks a parsed YANG module and produces a capability map plus a derivation
  report. Returns `{:ok, capability_map, report}` or `{:error, [errors]}`.

  `capability_map` is the shape consumed by `Wagger.Generator.Mcp.Builder.build_module/2`.
  """
  def derive(parsed_module, app_name) when is_binary(app_name) do
    rpcs = parsed_module.rpcs || []
    body = parsed_module.body || []

    lists = Enum.filter(body, &match?(%ExYang.Model.List{}, &1))
    containers = Enum.filter(body, &match?(%ExYang.Model.Container{}, &1))

    {tools, tool_warns} = derive_tools(rpcs)
    {resources, resource_issues} = derive_resources(lists ++ containers)
    {prompts, prompt_warns} = derive_prompts(rpcs)

    excluded_nodes = collect_excluded(rpcs, lists ++ containers)

    {warnings, errors} = split_issues(resource_issues)
    warnings = warnings ++ tool_warns ++ prompt_warns

    duplicate_errors = check_duplicate_tools(tools)

    case errors ++ duplicate_errors do
      [] ->
        caps = %{
          app_name: app_name,
          tools: tools,
          resources: resources,
          prompts: prompts
        }

        report = %{
          tools_count: length(tools),
          resources_count: length(resources),
          prompts_count: length(prompts),
          tools: tools,
          resources: resources,
          prompts: prompts,
          warnings: warnings,
          excluded: excluded_nodes
        }

        {:ok, caps, report}

      es ->
        {:error, es}
    end
  end

  defp split_issues(issues) do
    Enum.split_with(issues, fn %{kind: k} ->
      k in [:mime_type_default, :description_fallback]
    end)
  end

  defp collect_excluded(rpcs, body) do
    rpc_excl =
      for rpc <- rpcs, extension_present?(rpc.extensions, "exclude"), do: "/rpcs/#{rpc.name}"

    body_excl =
      for n <- body, excluded?(n) do
        case n do
          %ExYang.Model.List{name: name} -> "/lists/#{name}"
          %ExYang.Model.Container{name: name} -> "/containers/#{name}"
        end
      end

    rpc_excl ++ body_excl
  end

  defp check_duplicate_tools(tools) do
    names = Enum.map(tools, & &1.name)
    dups = names -- Enum.uniq(names)

    Enum.map(Enum.uniq(dups), fn n ->
      %{node: "/tools/#{n}", kind: :duplicate_tool_name, message: "duplicate tool name: #{n}"}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
