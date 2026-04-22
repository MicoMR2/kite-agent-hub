defmodule KiteAgentHub.Repo.Migrations.CreatePolymarketPositions do
  use Ecto.Migration

  def change do
    create table(:polymarket_positions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :kite_agent_id, references(:kite_agents, type: :binary_id, on_delete: :nilify_all)
      add :market_id, :string, null: false
      add :token_id, :string, null: false
      add :outcome, :string, null: false
      add :size, :decimal, precision: 20, scale: 6, null: false, default: 0
      add :avg_price, :decimal, precision: 10, scale: 6, null: false, default: 0
      add :realized_pnl, :decimal, precision: 20, scale: 6, null: false, default: 0
      add :mode, :string, null: false, default: "paper"
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:polymarket_positions, [:organization_id])
    create index(:polymarket_positions, [:kite_agent_id])
    create index(:polymarket_positions, [:market_id])
  end
end
