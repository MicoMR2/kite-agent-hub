defmodule KiteAgentHubWeb.API.HistoricalTradesControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Repo, Trading}

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  defp settle(scope, attrs) do
    trade = trade_fixture(scope, attrs)

    {:ok, settled} =
      Repo.with_user(scope.user.id, fn ->
        Trading.update_trade(trade, %{
          "status" => "settled",
          "realized_pnl" => attrs[:realized_pnl] || Decimal.new(0)
        })
      end)

    settled
  end

  describe "GET /api/v1/historical-trades" do
    test "401 without bearer token", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/historical-trades"), 401)["ok"] == false
    end

    test "returns empty summary for an agent with no trades", %{conn: conn} do
      %{agent: agent} = agent_scope_fixture()

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> get(~p"/api/v1/historical-trades")
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["agent_id"] == agent.id
      assert resp["summary"]["settled_trades"] == 0
      assert resp["summary"]["total_pnl"] == "0"
      assert resp["summary"]["win_rate"] == nil
      assert resp["by_platform"] == []
      assert resp["by_market"] == []
      assert resp["recent"] == []
    end

    test "aggregates settled trades into summary, by_platform, and by_market", %{conn: conn} do
      scope = agent_scope_fixture()

      _ =
        settle(scope, %{
          platform: "alpaca",
          market: "AAPL",
          realized_pnl: Decimal.new("10.00")
        })

      _ =
        settle(scope, %{
          platform: "alpaca",
          market: "AAPL",
          realized_pnl: Decimal.new("-3.00")
        })

      _ =
        settle(scope, %{
          platform: "oanda",
          market: "EUR_USD",
          realized_pnl: Decimal.new("2.50")
        })

      resp =
        conn
        |> auth(Repo.reload!(scope.agent))
        |> get(~p"/api/v1/historical-trades")
        |> json_response(200)

      assert resp["summary"]["settled_trades"] == 3
      assert resp["summary"]["win_count"] == 2
      assert resp["summary"]["loss_count"] == 1
      assert resp["summary"]["win_rate"] == 0.6667
      assert resp["summary"]["total_pnl"] == "9.50"

      platforms = Map.new(resp["by_platform"], &{&1["platform"], &1})
      assert platforms["alpaca"]["trades"] == 2
      assert platforms["oanda"]["trades"] == 1

      markets = Map.new(resp["by_market"], &{&1["market"], &1})
      assert markets["AAPL"]["trades"] == 2
      assert markets["EUR_USD"]["trades"] == 1
    end

    test "platform filter restricts the summary", %{conn: conn} do
      scope = agent_scope_fixture()

      _ = settle(scope, %{platform: "alpaca", realized_pnl: Decimal.new("5.00")})
      _ = settle(scope, %{platform: "oanda", realized_pnl: Decimal.new("3.00")})

      resp =
        conn
        |> auth(Repo.reload!(scope.agent))
        |> get(~p"/api/v1/historical-trades?platform=oanda")
        |> json_response(200)

      assert resp["summary"]["settled_trades"] == 1
      assert resp["summary"]["total_pnl"] == "3.00"
      assert length(resp["by_platform"]) == 1
      assert hd(resp["by_platform"])["platform"] == "oanda"
    end

    test "limit clamps the recent sample to 1..100", %{conn: conn} do
      %{agent: agent} = agent_scope_fixture()

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> get(~p"/api/v1/historical-trades?limit=999")
        |> json_response(200)

      # Clamped to 100 by the controller
      assert resp["filters"]["limit"] == 100
    end
  end
end
