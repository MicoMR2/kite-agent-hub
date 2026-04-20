defmodule KiteAgentHub.Repo.Migrations.AddLlmFieldsToKiteAgents do
  use Ecto.Migration

  def change do
    alter table(:kite_agents) do
      add :llm_provider, :string
      add :llm_model, :string
      add :llm_endpoint_url, :string
    end
  end
end
