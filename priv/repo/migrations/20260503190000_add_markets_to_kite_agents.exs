defmodule KiteAgentHub.Repo.Migrations.AddMarketsToKiteAgents do
  use Ecto.Migration

  # Markets the agent is configured to trade. Empty array means "no
  # markets selected yet" — surfaces a hint in the agent context so the
  # LLM knows to ask the user before placing trades. Whitelist is
  # enforced by the schema, not the column.
  def change do
    alter table(:kite_agents) do
      add :markets, {:array, :string}, default: [], null: false
    end
  end
end
