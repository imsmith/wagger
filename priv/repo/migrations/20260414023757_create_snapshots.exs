defmodule Wagger.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:snapshots) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :config_params, :text
      add :route_snapshot, :text, null: false
      add :output, :text, null: false
      add :checksum, :string, null: false
      timestamps(type: :string, updated_at: false)
    end

    create index(:snapshots, [:application_id])
    create index(:snapshots, [:application_id, :provider])
  end
end
