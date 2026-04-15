defmodule WaggerWeb.GenerateController do
  @moduledoc """
  Controller for generating WAF configuration from stored application routes.

  Accepts a provider name and optional config params, runs the generation pipeline,
  stores an immutable snapshot (with encrypted output and context metadata), and
  returns the generated output with the snapshot ID.

  Errors from the generator pipeline are returned as structured
  `Comn.Errors.ErrorStruct` JSON with `error`, `reason`, `field`, and `suggestion`.
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

  @doc "Generates WAF config for the given application and provider, stores a snapshot."
  def create(conn, %{"application_id" => app_id, "provider" => provider} = params) do
    config = Map.drop(params, ["application_id", "provider"])

    case Map.fetch(@providers, provider) do
      :error ->
        err = Comn.Errors.Registry.error!("wagger.generator/unknown_provider",
          message: "Unknown provider: #{provider}",
          field: "provider"
        )

        conn
        |> put_status(:bad_request)
        |> json(%{error: err.message, code: err.code, field: err.field})

      {:ok, module} ->
        app = Applications.get_application!(app_id)
        routes = Routes.list_routes(app)
        route_data = Drift.normalize_for_snapshot(routes)

        case Generator.generate(module, route_data, config) do
          {:ok, output} ->
            checksum = Drift.compute_checksum(route_data)

            ctx = Comn.Contexts.get()

            {:ok, snapshot} =
              Snapshots.create_snapshot(%{
                application_id: app.id,
                provider: provider,
                config_params: Jason.encode!(config),
                route_snapshot: :erlang.term_to_binary(route_data) |> Base.encode64(),
                output: output,
                checksum: checksum,
                request_id: ctx && ctx.request_id,
                generated_by: ctx && ctx.actor
              })

            Wagger.Events.config_generated(app, provider, snapshot.id)
            render(conn, :created, output: output, provider: provider, snapshot_id: snapshot.id)

          {:error, %Comn.Errors.ErrorStruct{} = err} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: err.message, reason: err.reason, field: err.field, suggestion: err.suggestion})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end
    end
  end
end
