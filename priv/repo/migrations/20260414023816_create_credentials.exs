defmodule Wagger.Repo.Migrations.CreateCredentials do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :label, :string
      add :credential_data, :binary, null: false
      timestamps(type: :string, updated_at: false)
    end

    create index(:credentials, [:user_id])
  end
end
