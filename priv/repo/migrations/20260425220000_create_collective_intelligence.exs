defmodule KiteAgentHub.Repo.Migrations.CreateCollectiveIntelligence do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :collective_intelligence_enabled, :boolean, null: false, default: false
      add :collective_intelligence_consented_at, :utc_datetime
      add :collective_intelligence_consent_version, :string
    end

    create table(:collective_trade_insights, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :source_trade_hash, :string, null: false
      add :source_org_hash, :string, null: false
      add :agent_type, :string, null: false
      add :platform, :string, null: false
      add :market_class, :string, null: false
      add :side, :string
      add :action, :string
      add :status, :string, null: false
      add :outcome_bucket, :string, null: false
      add :notional_bucket, :string
      add :hold_time_bucket, :string
      add :observed_week, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:collective_trade_insights, [:source_trade_hash])
    create index(:collective_trade_insights, [:source_org_hash])
    create index(:collective_trade_insights, [:platform, :market_class])
    create index(:collective_trade_insights, [:outcome_bucket])
    create index(:collective_trade_insights, [:observed_week])
  end
end
