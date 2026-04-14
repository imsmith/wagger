defmodule Wagger.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :display_name, :string
      add :password_hash, :string
      add :api_key_hash, :string
      timestamps(type: :string)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:api_key_hash])
  end
end
