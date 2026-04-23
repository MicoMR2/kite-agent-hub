defmodule KiteAgentHub.Repo.Migrations.CreateWalletsVaultsOnboarding do
  use Ecto.Migration

  def change do
    create table(:wallets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :balance_usd, :decimal, precision: 15, scale: 2, null: false, default: 0
      add :currency, :string, null: false, default: "USD"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:wallets, [:user_id])

    create table(:vaults) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :encrypted_credentials, :binary
      add :iv, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:vaults, [:user_id])

    alter table(:users) do
      add :onboarding_completed_at, :utc_datetime
    end
  end
end
