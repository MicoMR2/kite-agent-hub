defmodule KiteAgentHub.Repo.Migrations.AddRiskConfigToKiteAgents do
  use Ecto.Migration

  # Per-agent risk overrides. Empty map means "use module-level
  # defaults" — existing agents keep current behavior on deploy. The
  # schema enforces the whitelist of keys + value bounds; this column
  # is intentionally a free-form jsonb at the storage layer so that
  # adding a new tunable later is a code-only change with a Trading.Risk
  # default. Hard server ceilings (e.g. $5K notional cap) live in the
  # changeset, not the column.
  def change do
    alter table(:kite_agents) do
      add :risk_config, :map, default: %{}, null: false
    end
  end
end
