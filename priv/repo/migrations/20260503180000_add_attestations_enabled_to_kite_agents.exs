defmodule KiteAgentHub.Repo.Migrations.AddAttestationsEnabledToKiteAgents do
  use Ecto.Migration

  # Default new agents to attestations OFF — most users will want to
  # trade Alpaca/Kalshi/OANDA without ever touching Kite chain. Existing
  # agents that already have a wallet stay attesting so we don't break
  # in-flight on-chain history mid-flight.
  def up do
    alter table(:kite_agents) do
      add :attestations_enabled, :boolean, default: false, null: false
    end

    flush()

    execute("""
    UPDATE kite_agents
    SET attestations_enabled = TRUE
    WHERE wallet_address IS NOT NULL AND wallet_address <> ''
    """)
  end

  def down do
    alter table(:kite_agents) do
      remove :attestations_enabled
    end
  end
end
