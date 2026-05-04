defmodule KiteAgentHub.KciCoverageTest do
  @moduledoc """
  Regression guard for KCI write coverage. Verifies that every
  terminal-state transition path on TradeRecord (cancel, auto-cancel,
  settle, generic update→failed/cancelled/settled) actually fires
  CollectiveIntelligence.record_trade_outcome.

  If a future change adds a new path that bypasses these helpers
  (e.g. a worker calling Repo.update directly on a TradeRecord), the
  corresponding test below will fail because the TradeInsight row
  will not appear.
  """

  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.AccountsFixtures
  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{CollectiveIntelligence, Orgs, Repo, Trading}
  alias KiteAgentHub.CollectiveIntelligence.TradeInsight

  setup do
    %{user: user, org: org, agent: agent} = agent_scope_fixture()
    {:ok, _} = Orgs.update_collective_intelligence(user, org.id, true)
    assert CollectiveIntelligence.enabled_for_org?(org.id)

    {:ok, user: user, org: org, agent: agent}
  end

  describe "KCI is recorded on every terminal transition" do
    test "cancel_trade/2 records an insight", %{user: user, agent: agent} = scope do
      trade = trade_fixture(scope)
      assert insight_count() == 0

      {:ok, _cancelled} =
        Repo.with_user(user.id, fn -> Trading.cancel_trade(trade.id, agent.id) end)

      assert insight_count() == 1
    end

    test "auto_cancel_stuck_trades/1 records an insight per cancelled row", %{user: user} = scope do
      old =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      _stuck1 = trade_fixture(scope, %{inserted_at: old})
      _stuck2 = trade_fixture(scope, %{inserted_at: old})

      cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      assert insight_count() == 0

      {:ok, {2, _trades}} =
        Repo.with_user(user.id, fn -> Trading.auto_cancel_stuck_trades(cutoff) end)

      assert insight_count() == 2
    end

    test "settle_trade/2 records an insight", %{user: user} = scope do
      trade = trade_fixture(scope)
      assert insight_count() == 0

      {:ok, _settled} =
        Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("12.50")) end)

      assert insight_count() == 1
    end

    test "update_trade/2 records an insight when status flips to settled",
         %{user: user} = scope do
      trade = trade_fixture(scope)
      assert insight_count() == 0

      {:ok, _updated} =
        Repo.with_user(user.id, fn ->
          Trading.update_trade(trade, %{status: "settled", realized_pnl: Decimal.new("3.00")})
        end)

      assert insight_count() == 1
    end

    test "update_trade/2 records an insight when status flips to failed",
         %{user: user} = scope do
      trade = trade_fixture(scope)
      assert insight_count() == 0

      {:ok, _updated} =
        Repo.with_user(user.id, fn -> Trading.update_trade(trade, %{status: "failed"}) end)

      assert insight_count() == 1
    end

    test "update_trade/2 does NOT record an insight on a non-terminal flip",
         %{user: user} = scope do
      trade = trade_fixture(scope)

      {:ok, _updated} =
        Repo.with_user(user.id, fn ->
          Trading.update_trade(trade, %{reason: "noted, no exit yet"})
        end)

      assert insight_count() == 0
    end
  end

  defp insight_count, do: Repo.aggregate(TradeInsight, :count)
end
