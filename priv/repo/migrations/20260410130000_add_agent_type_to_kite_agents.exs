defmodule KiteAgentHub.Repo.Migrations.AddAgentTypeToKiteAgents do
  use Ecto.Migration

  def change do
    alter table(:kite_agents) do
      add :agent_type, :string, null: false, default: "trading"
      modify :wallet_address, :string, null: true
    end
  end
end
