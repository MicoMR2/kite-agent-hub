defmodule KiteAgentHub.Repo.Migrations.KciV2KalshiExtension do
  use Ecto.Migration

  # PR-K3a: KCI v2 schema additions for Kalshi-specific outcome
  # buckets. All columns nullable so v1 rows stay null (CyberSec
  # 10831 ① additive-only). Org-side consent tracking already exists
  # via `organizations.collective_intelligence_consent_version` — no
  # new org column needed. No v1 backfill (CyberSec ⑥).
  def change do
    alter table(:collective_trade_insights) do
      add :lifecycle_stage_at_exit, :string
      add :implied_prob_at_entry_bucket, :string
      add :consent_version, :string
    end
  end
end
