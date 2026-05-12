defmodule KiteAgentHub.Trading.RealizedPnlTest do
  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading
  alias KiteAgentHub.Trading.TradeRecord

  setup do
    %{user: user, agent: agent} = agent_scope_fixture(%{agent_type: "trading"})
    %{user: user, agent: agent}
  end

  defp insert_settled_trade!(scope, attrs) do
    base = %{
      market: "AAPL",
      platform: "kite",
      action: "buy",
      contracts: 10,
      fill_price: Decimal.new("100.00"),
      status: "settled"
    }

    trade_fixture(scope, Map.merge(base, attrs))
  end

  describe "compute_realized_pnl_for_sell/1" do
    test "single buy → sell at higher price returns positive PnL", %{user: user, agent: agent} do
      _buy = insert_settled_trade!(%{user: user, agent: agent}, %{action: "buy", contracts: 10, fill_price: Decimal.new("100.00")})
      sell = insert_settled_trade!(%{user: user, agent: agent}, %{action: "sell", contracts: 10, fill_price: Decimal.new("110.00")})

      pnl = Trading.compute_realized_pnl_for_sell(sell)
      # (110 - 100) * 10 = 100
      assert Decimal.equal?(pnl, Decimal.new("100.00"))
    end

    test "sell at lower price returns negative PnL", %{user: user, agent: agent} do
      _buy = insert_settled_trade!(%{user: user, agent: agent}, %{action: "buy", contracts: 5, fill_price: Decimal.new("50.00")})
      sell = insert_settled_trade!(%{user: user, agent: agent}, %{action: "sell", contracts: 5, fill_price: Decimal.new("40.00")})

      pnl = Trading.compute_realized_pnl_for_sell(sell)
      # (40 - 50) * 5 = -50
      assert Decimal.equal?(pnl, Decimal.new("-50.00"))
    end

    test "partial fill consumes oldest lot first (FIFO)", %{user: user, agent: agent} do
      # Two buys at different prices, sell of partial size.
      _ = insert_settled_trade!(%{user: user, agent: agent}, %{
            action: "buy",
            contracts: 5,
            fill_price: Decimal.new("100.00"),
            inserted_at: ~U[2026-05-01 10:00:00Z]
          })

      _ = insert_settled_trade!(%{user: user, agent: agent}, %{
            action: "buy",
            contracts: 5,
            fill_price: Decimal.new("110.00"),
            inserted_at: ~U[2026-05-01 11:00:00Z]
          })

      sell =
        insert_settled_trade!(%{user: user, agent: agent}, %{
          action: "sell",
          contracts: 5,
          fill_price: Decimal.new("120.00"),
          inserted_at: ~U[2026-05-01 12:00:00Z]
        })

      pnl = Trading.compute_realized_pnl_for_sell(sell)
      # FIFO consumes the $100 lot first → (120 - 100) * 5 = 100
      assert Decimal.equal?(pnl, Decimal.new("100.00"))
    end

    test "buy action returns 0", %{user: user, agent: agent} do
      buy = insert_settled_trade!(%{user: user, agent: agent}, %{action: "buy"})
      assert Decimal.equal?(Trading.compute_realized_pnl_for_sell(buy), Decimal.new(0))
    end

    test "sell with no prior buys returns 0 (defensive)", %{user: user, agent: agent} do
      sell = insert_settled_trade!(%{user: user, agent: agent}, %{action: "sell", contracts: 3, fill_price: Decimal.new("50.00")})
      assert Decimal.equal?(Trading.compute_realized_pnl_for_sell(sell), Decimal.new(0))
    end

    test "nil fill_price returns 0 (defensive — bad broker data)", %{user: user, agent: agent} do
      sell = %TradeRecord{
        kite_agent_id: agent.id,
        market: "AAPL",
        platform: "kite",
        action: "sell",
        contracts: 5,
        fill_price: nil,
        status: "settled",
        inserted_at: ~U[2026-05-01 12:00:00Z]
      }

      assert Decimal.equal?(Trading.compute_realized_pnl_for_sell(sell), Decimal.new(0))
    end

    test "cross-agent isolation — buys from another agent are NOT consumed", %{user: user, agent: agent} do
      # Another agent in another org has a cheap buy that should NEVER
      # be matched against our sell (CyberSec ask 3, msg 9222).
      %{user: other_user, agent: other_agent} = agent_scope_fixture(%{agent_type: "trading"})

      _ = insert_settled_trade!(%{user: other_user, agent: other_agent}, %{
            action: "buy",
            contracts: 100,
            fill_price: Decimal.new("1.00")
          })

      sell = insert_settled_trade!(%{user: user, agent: agent}, %{action: "sell", contracts: 5, fill_price: Decimal.new("50.00")})

      # No prior buy on OUR agent → returns 0, ignoring the other agent's
      # 100-share buy at $1.
      assert Decimal.equal?(Trading.compute_realized_pnl_for_sell(sell), Decimal.new(0))

      _ = Repo.aggregate(TradeRecord, :count)
    end

    test "cross-market isolation — buys on another market are NOT consumed", %{user: user, agent: agent} do
      _ = insert_settled_trade!(%{user: user, agent: agent}, %{
            action: "buy",
            market: "MSFT",
            contracts: 10,
            fill_price: Decimal.new("100.00")
          })

      sell = insert_settled_trade!(%{user: user, agent: agent}, %{
              action: "sell",
              market: "AAPL",
              contracts: 10,
              fill_price: Decimal.new("110.00")
            })

      assert Decimal.equal?(Trading.compute_realized_pnl_for_sell(sell), Decimal.new(0))
    end
  end
end
