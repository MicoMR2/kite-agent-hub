defmodule KiteAgentHubWeb.API.PortfolioControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  setup do
    %{agent: agent} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent)}
  end

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/portfolio" do
    test "401 when no bearer token", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/portfolio")
      assert json_response(conn, 401) == %{"ok" => false, "error" => "invalid api key"}
    end

    test "401 when token is unknown", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> get(~p"/api/v1/portfolio")

      assert json_response(conn, 401)["ok"] == false
    end

    test "400 when alpaca credentials are not configured", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent)
        |> get(~p"/api/v1/portfolio")
        |> json_response(400)

      assert resp["ok"] == false
      assert resp["error"] =~ "alpaca credentials"
    end
  end
end
