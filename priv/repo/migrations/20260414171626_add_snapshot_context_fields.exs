defmodule Wagger.Repo.Migrations.AddSnapshotContextFields do
  use Ecto.Migration

  @moduledoc false

  def change do
    alter table(:snapshots) do
      add :request_id, :string
      add :generated_by, :string
    end
  end
end
