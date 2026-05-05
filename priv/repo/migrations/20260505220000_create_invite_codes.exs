defmodule Wagger.Repo.Migrations.CreateInviteCodes do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:invite_codes) do
      add :code, :string, null: false
      add :label, :string
      add :expires_at, :string
      add :max_uses, :integer
      add :uses_count, :integer, default: 0, null: false
      add :revoked_at, :string
      add :created_by_user_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :string)
    end

    create unique_index(:invite_codes, [:code])
    create index(:invite_codes, [:created_by_user_id])
  end
end
