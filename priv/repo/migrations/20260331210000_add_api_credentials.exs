defmodule KiteAgentHub.Repo.Migrations.AddApiCredentials do
  use Ecto.Migration

  def change do
    create table(:api_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :key_id, :string, null: false
      add :encrypted_secret, :binary, null: false
      add :iv, :binary, null: false
      add :tag, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:api_credentials, [:org_id, :provider])
    create index(:api_credentials, [:org_id])
  end
end
