defmodule KiteAgentHubWeb.API.ForexPortfolioControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  setup do
    %{agent: agent} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent)}
  end

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/forex/portfolio" do
    test "401 when no bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/forex/portfolio")
      assert json_response(conn, 401)["ok"] == false
    end

    test "401 when token is unknown", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/api/v1/forex/portfolio")

      assert json_response(conn, 401)["ok"] == false
    end

    test "200 with readiness fields when oanda_practice not configured", %{
      conn: conn,
      agent: agent
    } do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/forex/portfolio")
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["provider"] == "oanda_practice"
      assert resp["env"] == "practice"
      assert resp["can_submit_trades"] == false
      assert resp["trade_provider"] == nil
      assert resp["account"] == nil
      assert resp["positions"] == []
      assert resp["instruments"] == []
      assert resp["pricing"] == []
      assert is_binary(resp["order_note"])
      assert resp["order_note"] =~ "oanda_practice"
      assert resp["error"] =~ "oanda_practice credentials"
    end

    test "env=live changes the provider label", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/forex/portfolio?env=live")
        |> json_response(200)

      assert resp["provider"] == "oanda_live"
      assert resp["env"] == "live"
      # Live is a read-only data source. Trading still requires practice creds.
      assert resp["trade_provider"] == nil
      assert resp["can_submit_trades"] == false
    end
  end
end
