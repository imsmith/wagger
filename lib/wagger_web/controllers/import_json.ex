defmodule WaggerWeb.ImportJSON do
  @moduledoc false

  def preview(%{preview: preview}) do
    %{
      preview_token: preview.preview_token,
      parsed: Enum.map(preview.parsed, &render_parsed/1),
      conflicts: Enum.map(preview.conflicts, &render_conflict/1),
      skipped: preview.skipped
    }
  end

  def confirm(%{inserted: inserted}) do
    %{
      inserted: Enum.map(inserted, &render_inserted/1)
    }
  end

  defp render_parsed(route) do
    %{
      path: Map.get(route, :path) || Map.get(route, "path"),
      methods: Map.get(route, :methods) || Map.get(route, "methods"),
      path_type: Map.get(route, :path_type) || Map.get(route, "path_type"),
      description: Map.get(route, :description) || Map.get(route, "description")
    }
  end

  defp render_conflict(conflict) do
    %{
      path: conflict.path,
      existing: %{methods: conflict.existing.methods},
      incoming: %{methods: Map.get(conflict.incoming, :methods) || Map.get(conflict.incoming, "methods")}
    }
  end

  defp render_inserted(route) do
    %{
      id: route.id,
      path: route.path,
      methods: route.methods,
      path_type: route.path_type
    }
  end
end
