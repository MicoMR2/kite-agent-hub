defmodule KiteAgentHub.Repo.Migrations.CreateKiteAgents do
  use Ecto.Migration

  def change do
    create table(:kite_agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :wallet_address, :string, null: false
      add :vault_address, :string
      add :chain_id, :integer, default: 2368
      add :daily_limit_usd, :integer, default: 1000
      add :per_trade_limit_usd, :integer, default: 500
      add :max_open_positions, :integer, default: 10
      add :status, :string, default: "pending"
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:kite_agents, [:wallet_address])
    create index(:kite_agents, [:organization_id])
  end
end
