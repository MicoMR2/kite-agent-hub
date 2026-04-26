defmodule KiteAgentHub.CollectiveIntelligenceTest do
  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{CollectiveIntelligence, Orgs, Repo, Trading}
  alias KiteAgentHub.CollectiveIntelligence.TradeInsight

  test "settled trades are ignored until the workspace opts in" do
    %{user: user, org: org} = scope = trading_scope_fixture()
    trade = trade_fixture(scope, %{platform: "alpaca", market: "AAPL", status: "open"})

    {:ok, {:ok, _settled}} =
      Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("12.50")) end)

    assert CollectiveIntelligence.enabled_for_org?(org.id) == false
    assert Repo.aggregate(TradeInsight, :count) == 0
  end

  test "opted-in workspaces store only anonymized bucketed trade outcomes" do
    %{user: user, org: org} = scope = trading_scope_fixture()
    assert {:ok, enabled_org} = Orgs.update_collective_intelligence(user, org.id, true)
    assert enabled_org.collective_intelligence_enabled == true

    trade =
      trade_fixture(scope, %{
        platform: "alpaca",
        market: "AAPL260117C00100000",
        status: "open",
        notional_usd: Decimal.new("125.00")
      })

    {:ok, {:ok, _settled}} =
      Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("25.00")) end)

    [insight] = Repo.all(TradeInsight)
    assert insight.agent_type == "trading"
    assert insight.platform == "alpaca"
    assert insight.market_class == "option"
    assert insight.outcome_bucket == "profit"
    assert insight.notional_bucket == "100_to_999"
    assert insight.source_trade_hash != trade.id
    assert insight.source_org_hash != org.id

    summary = CollectiveIntelligence.summary_for_org(org.id)
    assert summary.enabled == true
    assert [%{lesson: lesson}] = summary.insights
    assert lesson =~ "Use as context, not a guarantee"
  end

  test "opting out purges prior anonymized contributions for that workspace" do
    %{user: user, org: org} = scope = trading_scope_fixture()
    assert {:ok, _org} = Orgs.update_collective_intelligence(user, org.id, true)

    trade = trade_fixture(scope, %{platform: "alpaca", market: "SPY", status: "open"})

    {:ok, {:ok, _settled}} =
      Repo.with_user(user.id, fn -> Trading.settle_trade(trade, Decimal.new("-5.00")) end)

    assert Repo.aggregate(TradeInsight, :count) == 1

    assert {:ok, disabled_org} = Orgs.update_collective_intelligence(user, org.id, false)
    assert disabled_org.collective_intelligence_enabled == false
    assert Repo.aggregate(TradeInsight, :count) == 0
  end

  defp trading_scope_fixture do
    agent_scope_fixture(%{
      agent_type: "trading",
      wallet_address: "0x0000000000000000000000000000000000000001"
    })
  end
end
