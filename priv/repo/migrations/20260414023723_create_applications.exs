defmodule Wagger.Repo.Migrations.CreateApplications do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:applications) do
      add :name, :string, null: false
      add :description, :text
      add :tags, :text
      timestamps(type: :string)
    end

    create unique_index(:applications, [:name])
  end
end
