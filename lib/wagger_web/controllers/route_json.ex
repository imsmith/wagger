defmodule WaggerWeb.RouteJSON do
  @moduledoc false

  def index(%{routes: routes}) do
    %{data: Enum.map(routes, &data/1)}
  end

  def show(%{route: route}) do
    %{data: data(route)}
  end

  defp data(route) do
    %{
      id: route.id,
      application_id: route.application_id,
      path: route.path,
      methods: route.methods || ["GET"],
      path_type: route.path_type,
      description: route.description,
      query_params: route.query_params || [],
      headers: route.headers || [],
      rate_limit: route.rate_limit,
      tags: route.tags || [],
      inserted_at: route.inserted_at,
      updated_at: route.updated_at
    }
  end
end
