defmodule KiteAgentHub.Repo.Migrations.CreateAgentDdAuditLog do
  use Ecto.Migration

  def change do
    create table(:agent_dd_audit_log, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :kite_agent_id, references(:kite_agents, type: :binary_id, on_delete: :delete_all),
        null: false

      # Which threshold was evaluated.
      add :threshold_type, :string, null: false
      add :threshold_value, :decimal, null: true

      # Broker-reported NAV at check time + computed DD%.
      add :equity, :float, null: true
      add :dd_pct, :float, null: true

      # What the gate did: allowed | blocked | skipped.
      add :action, :string, null: false

      # Free-text reason — broker error message for `skipped`, threshold
      # quote for `blocked`, nil for `allowed`.
      add :reason, :text, null: true

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Hot query: "show me this agent's DD audit log, newest first."
    create index(:agent_dd_audit_log, [:kite_agent_id, :inserted_at])
  end
end
