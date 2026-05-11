defmodule KiteAgentHub.Repo.Migrations.CreateFeeAccruals do
  use Ecto.Migration

  def change do
    create table(:fee_accruals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # Audit record — keep the row after the agent or trade is gone.
      add :agent_id,
          references(:kite_agents, on_delete: :nilify_all, type: :binary_id)

      add :trade_id,
          references(:trade_records, on_delete: :nilify_all, type: :binary_id)

      # x402 payment receipt (opaque string from the agent's kpass
      # session). NEVER carries a JWT or secret — only the public
      # receipt blob.
      add :x402_receipt, :string, null: false
      add :amount_usdc, :decimal, null: false, default: 0
      add :accrued_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # Replay-attack guard. CyberSec ask #3 (msg 9076).
    create unique_index(:fee_accruals, [:x402_receipt])

    # Dashboard / surface query — accrual stream per agent over time.
    create index(:fee_accruals, [:agent_id, :accrued_at])
  end
end
