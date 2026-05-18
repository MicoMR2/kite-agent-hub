defmodule KiteAgentHub.Repo.Migrations.AddDrawdownThresholdsToKiteAgents do
  use Ecto.Migration

  def change do
    # User-configured drawdown thresholds. Nullable, default nil = OFF.
    # KAH executes the user's pre-set rule rather than imposing
    # platform-defined limits — see DrawdownGate moduledoc for the
    # legal framing (non-custodial / not investment-adviser).
    alter table(:kite_agents) do
      add :halt_at_dd_pct, :decimal, null: true
      add :flatten_at_dd_pct, :decimal, null: true
    end
  end
end
