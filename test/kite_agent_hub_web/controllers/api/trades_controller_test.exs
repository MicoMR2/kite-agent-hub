defmodule KiteAgentHubWeb.API.TradesControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/trades" do
    test "includes broker routing fields for stuck-order cleanup", %{conn: conn} do
      %{agent: agent} = scope = agent_scope_fixture()

      trade_fixture(scope, %{
        market: "SLB",
        platform: "alpaca",
        platform_order_id: "alpaca-order-123"
      })

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> get(~p"/api/v1/trades")
        |> json_response(200)

      [trade] = resp["trades"]
      assert trade["platform"] == "alpaca"
      assert trade["platform_order_id"] == "alpaca-order-123"
    end
  end

  describe "POST /api/v1/trades" do
    test "rejects forex-shaped symbols unless the OANDA provider is selected", %{conn: conn} do
      %{agent: agent} =
        agent_scope_fixture(%{
          agent_type: "trading",
          wallet_address: "0x0000000000000000000000000000000000000001"
        })

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> post(~p"/api/v1/trades", %{
          "market" => "EUR_USD",
          "side" => "long",
          "action" => "buy",
          "contracts" => 100,
          "fill_price" => 1.08,
          "reason" => "forex test"
        })
        |> json_response(400)

      assert resp["error"] =~ "provider=oanda_practice"
    end
  end
end
