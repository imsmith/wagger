defmodule WaggerWeb.DriftJSON do
  @moduledoc false

  def show(%{drift: drift}) do
    render_drift(drift)
  end

  defp render_drift(%{status: :never_generated, provider: provider}) do
    %{provider: provider, status: "never_generated"}
  end

  defp render_drift(%{status: :current, provider: provider, last_generated: last_generated}) do
    %{provider: provider, status: "current", last_generated: format_ts(last_generated)}
  end

  defp render_drift(%{
         status: :drifted,
         provider: provider,
         last_generated: last_generated,
         changes: changes
       }) do
    %{
      provider: provider,
      status: "drifted",
      last_generated: format_ts(last_generated),
      changes: render_changes(changes)
    }
  end

  defp render_changes(%{added: added, removed: removed, modified: modified}) do
    %{
      added: Enum.map(added, &route_summary/1),
      removed: Enum.map(removed, &route_summary/1),
      modified: Enum.map(modified, &modified_summary/1)
    }
  end

  # Added/removed entries from structural_diff are path strings (not maps).
  defp route_summary(path) when is_binary(path) do
    %{path: path}
  end

  defp route_summary(route) do
    %{path: route[:path] || route.path, methods: route[:methods] || route.methods}
  end

  # Modified entries from structural_diff are also path strings.
  defp modified_summary(path) when is_binary(path) do
    %{path: path}
  end

  defp modified_summary(%{path: path, current: current, previous: previous}) do
    %{
      path: path,
      current: route_summary(current),
      previous: route_summary(previous)
    }
  end

  defp format_ts(nil), do: nil
  defp format_ts(ts) when is_binary(ts), do: ts
  defp format_ts(ts), do: to_string(ts)
end
