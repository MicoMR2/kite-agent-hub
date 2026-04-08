defmodule KiteAgentHub.Repo.Migrations.DropSpendingLimitsFromKiteAgents do
  use Ecto.Migration

  @moduledoc """
  Removes the broken agent spending limit fields. Enforcement was inconsistent
  (agents opened more positions than the configured max_open_positions cap)
  and Mico called for clean removal — a broken limit is worse than no limit
  because users trust it. We can re-add a properly tested limits system in a
  later release.

  Drops:
    - daily_limit_usd
    - per_trade_limit_usd
    - max_open_positions
  """

  def change do
    alter table(:kite_agents) do
      remove :daily_limit_usd, :integer, default: 1000
      remove :per_trade_limit_usd, :integer, default: 500
      remove :max_open_positions, :integer, default: 10
    end
  end
end
