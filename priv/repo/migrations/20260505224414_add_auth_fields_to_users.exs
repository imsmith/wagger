defmodule Wagger.Repo.Migrations.AddAuthFieldsToUsers do
  use Ecto.Migration

  @moduledoc false

  def change do
    alter table(:users) do
      add :email, :string
      add :role, :string, default: "user", null: false
      add :invite_code_id, references(:invite_codes, on_delete: :nilify_all)
    end

    create unique_index(:users, [:email], where: "email IS NOT NULL")
    create index(:users, [:invite_code_id])

    execute(
      "UPDATE users SET role = 'admin' WHERE username = 'admin'",
      "UPDATE users SET role = 'user' WHERE username = 'admin'"
    )
  end
end
