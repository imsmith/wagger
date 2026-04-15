defmodule Wagger.Snapshots.Snapshot do
  @moduledoc """
  Ecto schema for a Snapshot — an immutable record of a WAF config generation event.

  Each snapshot captures the provider, input parameters, route data, generated output,
  and a checksum for deduplication. Snapshots are scoped to an Application and are
  never updated after creation.

  The `output` field is encrypted at rest via `Wagger.Secrets` (ChaCha20-Poly1305).
  Use `Wagger.Snapshots.decrypt_output/1` to read plaintext.

  The `request_id` and `generated_by` fields are populated from `Comn.Contexts`
  when generation is triggered via the authenticated API.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [
    type: :string,
    autogenerate: {Wagger.Applications.Application, :timestamp_now, []}
  ]

  schema "snapshots" do
    field :provider, :string
    field :config_params, :string
    field :route_snapshot, :string
    field :output, :string
    field :checksum, :string
    field :request_id, :string
    field :generated_by, :string
    belongs_to :application, Wagger.Applications.Application
    timestamps(type: :string, updated_at: false)
  end

  @doc """
  Changeset for creating a Snapshot.

  Casts all fields. Requires application_id, provider, route_snapshot, output, and checksum.
  """
  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:application_id, :provider, :config_params, :route_snapshot, :output, :checksum, :request_id, :generated_by])
    |> validate_required([:application_id, :provider, :route_snapshot, :output, :checksum])
  end
end
