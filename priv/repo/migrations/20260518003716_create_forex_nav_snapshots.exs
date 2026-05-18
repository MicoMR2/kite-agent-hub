defmodule KiteAgentHub.Repo.Migrations.CreateForexNavSnapshots do
  use Ecto.Migration

  def change do
    create table(:forex_nav_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :kite_agent_id, references(:kite_agents, type: :binary_id, on_delete: :delete_all),
        null: false

      # Unix-epoch seconds — matches the in-memory ring buffer in
      # `DashboardLive.append_forex_nav_sample/2` so the seed-from-DB
      # path drops in without a format conversion. inserted_at is
      # kept too for human-readable queries / retention sweeps.
      add :ts, :bigint, null: false
      add :nav, :float, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Primary read path: "give me the last N hours of NAV for agent X"
    # — the seed-from-DB load on Forex-tab mount. `(kite_agent_id, ts)`
    # descending covers the hot query without a sort step.
    create index(:forex_nav_snapshots, [:kite_agent_id, :ts])
  end
end
