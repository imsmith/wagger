defmodule Wagger.Repo.Migrations.CreateOauthIdentities do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:oauth_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :provider_uid, :string, null: false
      add :email, :string, null: false
      add :raw_info, :text
      timestamps(type: :string)
    end

    create unique_index(:oauth_identities, [:provider, :provider_uid])
    create index(:oauth_identities, [:user_id])
  end
end
