defmodule KiteAgentHub.Repo.Migrations.CreateAgentConfigChanges do
  use Ecto.Migration

  # Append-only audit trail for risk_config edits. Lives in its own
  # table (not a JSONB history column on kite_agents) so retention,
  # indexing, and RLS scope are independent of the agent row. Every
  # save of risk_config writes one row in the same Repo.transaction as
  # the agents update; partial saves are not possible.
  def change do
    create table(:agent_config_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:kite_agents, type: :binary_id, on_delete: :restrict),
        null: false

      add :user_id, references(:users, on_delete: :restrict), null: false

      add :prev_config, :map, default: %{}, null: false
      add :new_config, :map, default: %{}, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:agent_config_changes, [:agent_id])
    create index(:agent_config_changes, [:user_id])
    create index(:agent_config_changes, [:inserted_at])
  end
end
