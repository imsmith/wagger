defmodule WaggerWeb.ApplicationJSON do
  @moduledoc false

  def index(%{applications: applications}) do
    %{data: Enum.map(applications, &data/1)}
  end

  def show(%{application: application}) do
    %{data: data(application)}
  end

  defp data(app) do
    %{
      id: app.id,
      name: app.name,
      description: app.description,
      tags: app.tags || [],
      inserted_at: app.inserted_at,
      updated_at: app.updated_at
    }
  end
end
