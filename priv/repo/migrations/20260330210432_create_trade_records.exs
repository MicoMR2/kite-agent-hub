defmodule KiteAgentHub.Repo.Migrations.CreateTradeRecords do
  use Ecto.Migration

  def change do
    create table(:trade_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :trade_id_onchain, :string
      add :tx_hash, :string
      add :market, :string, null: false
      add :side, :string, null: false
      add :action, :string, null: false
      add :contracts, :integer, null: false
      add :fill_price, :decimal, null: false
      add :notional_usd, :decimal
      add :status, :string, default: "open"
      add :realized_pnl, :decimal
      add :source, :string
      add :reason, :string

      add :kite_agent_id, references(:kite_agents, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    create index(:trade_records, [:kite_agent_id])
    create index(:trade_records, [:status])
    create index(:trade_records, [:inserted_at])
  end
end
