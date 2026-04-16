defmodule KiteAgentHubWeb.API.KalshiMarketControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  setup do
    %{agent: agent} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent)}
  end

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/market-data/kalshi" do
    test "401 when no bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/market-data/kalshi")
      assert json_response(conn, 401) == %{"ok" => false, "error" => "invalid api key"}
    end

    test "400 when min_score is out of range", %{conn: conn, agent: agent} do
      resp =
        conn |> auth(agent) |> get(~p"/api/v1/market-data/kalshi?min_score=200") |> json_response(400)

      assert resp["error"] =~ "min_score"
    end

    test "400 when limit is out of range", %{conn: conn, agent: agent} do
      resp =
        conn |> auth(agent) |> get(~p"/api/v1/market-data/kalshi?limit=100000") |> json_response(400)

      assert resp["error"] =~ "limit"
    end

    test "400 when status is malformed", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/market-data/kalshi?status=BAD;DROP")
        |> json_response(400)

      assert resp["error"] =~ "status"
    end

    test "400 when kalshi credentials are not configured", %{conn: conn, agent: agent} do
      resp = conn |> auth(agent) |> get(~p"/api/v1/market-data/kalshi") |> json_response(400)
      assert resp["error"] =~ "kalshi credentials"
    end
  end
end
