defmodule KiteAgentHub.Repo.Migrations.CreateEdgeScoreSnapshots do
  use Ecto.Migration

  def change do
    create table(:edge_score_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all),
        null: false
      add :ticker, :string, null: false
      add :platform, :string, null: false
      add :score, :integer, null: false
      add :breakdown, :map, null: false, default: %{}
      add :recommendation, :string
      add :pnl_pct, :float

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Primary read path: "give me the last N hours of snapshots for
    # org X, ticker Y" — PortfolioEdgeScorer's output shape is one
    # row per (ticker, platform) tick, so (org_id, ticker, inserted_at)
    # covers the hot query with no table scan.
    create index(:edge_score_snapshots, [:organization_id, :ticker, :inserted_at])
  end
end
