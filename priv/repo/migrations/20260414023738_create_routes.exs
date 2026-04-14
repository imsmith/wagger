defmodule Wagger.Repo.Migrations.CreateRoutes do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:routes) do
      add :application_id, references(:applications, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :methods, :text, null: false
      add :path_type, :string, null: false, default: "exact"
      add :description, :text
      add :query_params, :text
      add :headers, :text
      add :rate_limit, :integer
      add :tags, :text
      timestamps(type: :string)
    end

    create index(:routes, [:application_id])
    create unique_index(:routes, [:application_id, :path])
  end
end
