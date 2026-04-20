defmodule KiteAgentHub.Repo.Migrations.CreateLlmUsageLogs do
  use Ecto.Migration

  def change do
    create table(:llm_usage_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :org_id, :binary_id, null: false
      add :agent_id, references(:kite_agents, type: :binary_id, on_delete: :nothing)
      add :provider, :string, null: false
      add :model, :string
      add :prompt_tokens, :integer
      add :completion_tokens, :integer
      add :cost_usd, :decimal, precision: 12, scale: 6
      add :source, :string, null: false, default: "internal"

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:llm_usage_logs, [:org_id, :inserted_at])
    create index(:llm_usage_logs, [:agent_id, :inserted_at])
  end
end
