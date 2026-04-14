defmodule Wagger.Repo.Migrations.AddApplicationFields do
  use Ecto.Migration

  @moduledoc false

  def change do
    alter table(:applications) do
      add :source, :text
      add :route_checksum, :string
      add :public, :boolean, default: false, null: false
      add :shareable, :boolean, default: false, null: false
    end
  end
end
