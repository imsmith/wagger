defmodule Wagger.Repo.Migrations.CreateOauthProviderCredentials do
  use Ecto.Migration

  @moduledoc false

  def change do
    create table(:oauth_provider_credentials) do
      add :provider, :string, null: false
      add :client_id, :string, null: false
      add :client_secret_locked, :text, null: false
      timestamps(type: :string)
    end

    create unique_index(:oauth_provider_credentials, [:provider])
  end
end
