defmodule WaggerWeb.GenerateController do
  @moduledoc """
  Controller for generating WAF configuration from stored application routes.

  Accepts a provider name and optional config params, runs the generation pipeline,
  stores an immutable snapshot, and returns the generated output with the snapshot ID.
  """

  use WaggerWeb, :controller

  alias Wagger.Applications
  alias Wagger.Drift
  alias Wagger.Generator
  alias Wagger.Routes
  alias Wagger.Snapshots

  action_fallback WaggerWeb.FallbackController

  @providers %{
    "nginx" => Wagger.Generator.Nginx,
    "aws" => Wagger.Generator.Aws,
    "cloudflare" => Wagger.Generator.Cloudflare,
    "azure" => Wagger.Generator.Azure,
    "gcp" => Wagger.Generator.Gcp,
    "caddy" => Wagger.Generator.Caddy,
    "coraza" => Wagger.Generator.Coraza,
    "zap" => Wagger.Generator.Zap
  }

  def create(conn, %{"application_id" => app_id, "provider" => provider} = params) do
    config = Map.drop(params, ["application_id", "provider"])

    case Map.fetch(@providers, provider) do
      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Unknown provider: #{provider}"})

      {:ok, module} ->
        app = Applications.get_application!(app_id)
        routes = Routes.list_routes(app)
        route_data = Drift.normalize_for_snapshot(routes)

        case Generator.generate(module, route_data, config) do
          {:ok, output} ->
            checksum = Drift.compute_checksum(route_data)

            {:ok, snapshot} =
              Snapshots.create_snapshot(%{
                application_id: app.id,
                provider: provider,
                config_params: Jason.encode!(config),
                route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
                output: output,
                checksum: checksum
              })

            render(conn, :created, output: output, provider: provider, snapshot_id: snapshot.id)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: reason})
        end
    end
  end
end
