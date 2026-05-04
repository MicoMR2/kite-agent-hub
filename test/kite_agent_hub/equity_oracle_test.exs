defmodule KiteAgentHub.EquityOracleTest do
  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.EquityOracle

  describe "missing-creds path returns :not_configured" do
    test "stock_snapshot/2 returns :not_configured when org has no Alpaca creds" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.stock_snapshot(org.id, "AAPL")
    end

    test "stock_snapshots/2 returns :not_configured when org has no Alpaca creds" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.stock_snapshots(org.id, ["AAPL", "SPY"])
    end

    test "stock_latest_quotes/2 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.stock_latest_quotes(org.id, ["AAPL"])
    end

    test "stock_latest_trades/2 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.stock_latest_trades(org.id, ["AAPL"])
    end

    test "stock_bars/4 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.stock_bars(org.id, "AAPL")
    end

    test "crypto_snapshots/2 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.crypto_snapshots(org.id, ["BTC/USD"])
    end

    test "crypto_latest_quotes/2 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.crypto_latest_quotes(org.id, ["BTC/USD"])
    end

    test "news/2 returns :not_configured" do
      %{org: org} = agent_scope_fixture()
      assert {:error, :not_configured} = EquityOracle.news(org.id, symbols: ["AAPL"])
    end
  end
end
