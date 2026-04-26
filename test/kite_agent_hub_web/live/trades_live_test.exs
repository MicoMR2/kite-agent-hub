defmodule KiteAgentHubWeb.TradesLiveTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Repo, Trading}
  alias KiteAgentHub.Trading.TradeRecord

  test "shows row P&L, platform, and attestation link", %{conn: conn} do
    %{user: user, agent: agent} = scope = agent_scope_fixture()

    buy_time = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    sell_time = DateTime.utc_now() |> DateTime.add(-1800, :second) |> DateTime.truncate(:second)

    trade_fixture(scope, %{
      action: "buy",
      status: "settled",
      market: "SLB",
      contracts: 2,
      fill_price: Decimal.new("40.00"),
      realized_pnl: Decimal.new("0"),
      platform: "alpaca",
      inserted_at: buy_time
    })

    sell =
      trade_fixture(scope, %{
        action: "sell",
        status: "settled",
        market: "SLB",
        contracts: 2,
        fill_price: Decimal.new("45.25"),
        realized_pnl: Decimal.new("0"),
        platform: "alpaca",
        inserted_at: sell_time
      })

    hash = "0x" <> String.duplicate("a", 64)

    {:ok, _sell} =
      Repo.with_user(user.id, fn ->
        sell
        |> Repo.reload!()
        |> TradeRecord.attestation_changeset(hash)
        |> Repo.update()
      end)

    conn = KiteAgentHubWeb.ConnCase.log_in_user(conn, user)
    {:ok, _view, html} = live(conn, ~p"/trades?agent_id=#{agent.id}")

    assert html =~ "+$10.50"
    assert html =~ "ALPACA"
    assert html =~ "kah-platform-alpaca"
    assert html =~ "https://testnet.kitescan.ai/tx/#{hash}"
  end

  test "Trading.list_trades_with_display_pnl leaves open buys without realized P&L" do
    %{user: user, agent: agent} = scope = agent_scope_fixture()
    trade_fixture(scope, %{action: "buy", status: "open", realized_pnl: nil})

    trades =
      Repo.with_user(user.id, fn ->
        Trading.list_trades_with_display_pnl(agent.id)
      end)
      |> elem(1)

    assert [%{display_pnl: nil}] = trades
  end
end
