defmodule KiteAgentHubWeb.API.EdgeScoresHistoryControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Repo, Trading}

  setup do
    %{agent: agent, org: org, user: user} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent), org: org, user: user}
  end

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  defp insert_snapshot(user, org, attrs) do
    {:ok, {:ok, row}} =
      Repo.with_user(user.id, fn ->
        Trading.insert_edge_score_snapshot(
          Map.merge(
            %{
              organization_id: org.id,
              ticker: "HAL",
              platform: "alpaca",
              score: 85,
              breakdown: %{entry_quality: 25, momentum: 20, risk_reward: 20, liquidity: 20},
              recommendation: "hold",
              pnl_pct: 0.12
            },
            attrs
          )
        )
      end)

    row
  end

  describe "GET /api/v1/edge-scores/history" do
    test "401 without bearer", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/edge-scores/history")
      assert json_response(conn, 401)["ok"] == false
    end

    test "400 when hours is out of range", %{conn: conn, agent: agent} do
      resp =
        conn |> auth(agent) |> get(~p"/api/v1/edge-scores/history?hours=500") |> json_response(400)

      assert resp["error"] =~ "hours"
    end

    test "400 when ticker is malformed", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/edge-scores/history?ticker=BAD%20;DROP")
        |> json_response(400)

      assert resp["error"] =~ "ticker"
    end

    test "400 when platform is not alpaca/kalshi", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/edge-scores/history?platform=robinhood")
        |> json_response(400)

      assert resp["error"] =~ "platform"
    end

    test "returns rows scoped to the authenticated agent's org only", %{
      conn: conn,
      agent: agent,
      org: org,
      user: user
    } do
      insert_snapshot(user, org, %{ticker: "HAL", score: 91})
      insert_snapshot(user, org, %{ticker: "HAL", score: 85})
      insert_snapshot(user, org, %{ticker: "SLB", score: 70})

      # Another org — must not leak.
      %{agent: _other_agent, org: other_org, user: other_user} = agent_scope_fixture()
      insert_snapshot(other_user, other_org, %{ticker: "HAL", score: 10})

      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/edge-scores/history?ticker=HAL&hours=1")
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["hours"] == 1
      assert resp["count"] == 2
      assert Enum.all?(resp["snapshots"], fn s -> s["ticker"] == "HAL" end)
      # No score of 10 from the other org.
      refute Enum.any?(resp["snapshots"], fn s -> s["score"] == 10 end)
    end

    test "filters by platform", %{conn: conn, agent: agent, org: org, user: user} do
      insert_snapshot(user, org, %{ticker: "HAL", platform: "alpaca", score: 90})
      insert_snapshot(user, org, %{ticker: "KX-1", platform: "kalshi", score: 50})

      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/edge-scores/history?platform=alpaca")
        |> json_response(200)

      assert resp["count"] == 1
      assert hd(resp["snapshots"])["platform"] == "alpaca"
    end
  end
end
