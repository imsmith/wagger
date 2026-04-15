defmodule Wagger.Events do
  @moduledoc """
  Wagger event broadcasting via Comn.EventBus and Comn.EventLog.

  Emits structured events for route mutations, config generation,
  application changes, and drift detection. All events are broadcast
  to local subscribers and recorded in the in-memory event log.
  """

  alias Comn.Events.EventStruct

  @doc "Emits a route lifecycle event (created, updated, deleted)."
  def route_changed(action, route) when action in [:created, :updated, :deleted] do
    emit(:route, "wagger.route.#{action}", %{
      path: route.path,
      application_id: route.application_id,
      methods: route.methods
    })
  end

  @doc "Emits a config generation event."
  def config_generated(app, provider, snapshot_id) do
    emit(:generation, "wagger.config.generated", %{
      application_id: app.id,
      application_name: app.name,
      provider: provider,
      snapshot_id: snapshot_id
    })
  end

  @doc "Emits an application lifecycle event (created, updated)."
  def app_changed(action, app) when action in [:created, :updated] do
    emit(:application, "wagger.app.#{action}", %{
      application_id: app.id,
      name: app.name
    })
  end

  @doc "Emits a drift detection event."
  def drift_detected(app, provider, status) do
    emit(:drift, "wagger.drift.detected", %{
      application_id: app.id,
      application_name: app.name,
      provider: provider,
      status: status
    })
  end

  defp emit(type, topic, data) do
    ctx = Comn.Contexts.get()
    enriched = if ctx, do: Map.put(data, :actor, ctx.actor), else: data

    event = EventStruct.new(type, topic, enriched, :wagger)
    Comn.EventBus.broadcast(topic, event)
    Comn.EventLog.record(event)
    :ok
  end
end
