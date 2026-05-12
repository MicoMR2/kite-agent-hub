defmodule KiteAgentHub.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # CyberSec ask (a) at msg 9199: actor_user_id and org_id are
      # plain UUID-as-text strings, NOT FKs. nilify_all on user/org
      # deletion would drop the actor identity from a historical row;
      # the no-FK design keeps the audit trail forever even if the
      # user/org rows are later removed. Audit integrity > referential
      # cleanliness.
      add :actor_user_id, :string, null: false
      add :org_id, :string, null: false

      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :string, null: false

      add :metadata, :map, null: false, default: %{}

      # Append-only — no updated_at, no soft-delete column.
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:audit_logs, [:actor_user_id, :inserted_at])
    create index(:audit_logs, [:org_id, :inserted_at])
    create index(:audit_logs, [:target_type, :target_id])
  end
end
