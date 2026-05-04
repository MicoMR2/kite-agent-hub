defmodule KiteAgentHub.CollectiveIntelligenceBackfillTest do
  @moduledoc """
  Coverage for `CollectiveIntelligence.backfill_org/1` — the
  retroactive corpus credit for orgs that opt into KCI after they
  have already settled trades.
  """

  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.AccountsFixtures
  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{CollectiveIntelligence, Orgs, Repo, Trading}
  alias KiteAgentHub.CollectiveIntelligence.TradeInsight

  describe "backfill_org/1" do
    test "returns :kci_not_enabled when org has not opted in" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :kci_not_enabled} = CollectiveIntelligence.backfill_org(org.id)
    end

    test "credits every settled trade for an opted-in org" do
      %{user: user, org: org} = scope = agent_scope_fixture()
      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, true)

      # Settle three trades. Each settle fires record_trade_outcome
      # once via Trading.settle_trade — but to simulate the "trades
      # existed BEFORE opt-in" case we need to insert + settle then
      # purge any KCI rows that were already inserted. Easiest: opt
      # OUT first, settle the trades (record_trade_outcome no-ops),
      # then opt IN and run backfill.
      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, false)

      Enum.each(1..3, fn _ ->
        trade = trade_fixture(scope)

        {:ok, _} =
          Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("1.50")) end)
      end)

      assert insight_count() == 0

      # Now opt in and backfill — all three should land in the corpus.
      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, true)

      assert {:ok, %{processed: 3, inserted: 3, skipped: 0}} =
               CollectiveIntelligence.backfill_org(org.id)

      assert insight_count() == 3
    end

    test "is idempotent — re-running does not duplicate insights" do
      %{user: user, org: org} = scope = agent_scope_fixture()
      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, false)

      Enum.each(1..2, fn _ ->
        trade = trade_fixture(scope)

        {:ok, _} =
          Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("0.50")) end)
      end)

      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, true)

      {:ok, first} = CollectiveIntelligence.backfill_org(org.id)
      {:ok, second} = CollectiveIntelligence.backfill_org(org.id)

      # First run inserted 2; second run processed 2 but inserted 0
      # because source_trade_hash dedup handled the conflict.
      assert first.inserted == 2
      assert second.inserted == 0
      assert second.processed == 2
      assert insight_count() == 2
    end

    test "skips open trades (no terminal outcome to bucket)" do
      %{user: user, org: org} = scope = agent_scope_fixture()
      {:ok, _} = Orgs.update_collective_intelligence(user, org.id, true)

      _open_trade = trade_fixture(scope)

      assert {:ok, %{processed: 0}} = CollectiveIntelligence.backfill_org(org.id)
      assert insight_count() == 0
    end
  end

  defp insight_count, do: Repo.aggregate(TradeInsight, :count)
end
