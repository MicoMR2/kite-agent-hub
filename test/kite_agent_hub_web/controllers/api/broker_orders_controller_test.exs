defmodule KiteAgentHubWeb.API.BrokerOrdersControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  setup do
    %{agent: agent} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent)}
  end

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/broker/orders" do
    test "401 when no bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/broker/orders")
      assert json_response(conn, 401) == %{"ok" => false, "error" => "invalid api key"}
    end

    test "400 when status is malformed", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/broker/orders?status=../injected")
        |> json_response(400)

      assert resp["error"] =~ "status"
    end

    test "400 when limit is out of range", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/broker/orders?limit=0")
        |> json_response(400)

      assert resp["error"] =~ "limit"

      resp2 =
        build_conn()
        |> auth(agent)
        |> get(~p"/api/v1/broker/orders?limit=100000")
        |> json_response(400)

      assert resp2["error"] =~ "limit"
    end

    test "400 when alpaca credentials are not configured", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/broker/orders")
        |> json_response(400)

      assert resp["error"] =~ "alpaca credentials"
    end
  end
end
