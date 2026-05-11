defmodule KiteAgentHub.Repo.Migrations.CreateTriggerEvents do
  use Ecto.Migration

  def change do
    create table(:trigger_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id,
          references(:kite_agents, on_delete: :delete_all, type: :binary_id),
          null: false

      add :event_type, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"

      # Replay guard for Passport PR-3 dispatcher. AgentRunner re-ticks
      # and Oban retries can both re-fire the same trade intent; the
      # idempotency key (deterministic sha256 over normalized payload)
      # collapses duplicates at the unique index level.
      add :idempotency_key, :string, null: false

      add :delivered_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # DB-enforced replay guard — CyberSec ask #1.
    create unique_index(:trigger_events, [:idempotency_key])

    # PR-6 (GET /api/triggers/pending) filter — CyberSec ask #2.
    create index(:trigger_events, [:agent_id, :status])

    # TTL cleanup sweep — CyberSec ask #3.
    create index(:trigger_events, [:delivered_at])
  end
end
