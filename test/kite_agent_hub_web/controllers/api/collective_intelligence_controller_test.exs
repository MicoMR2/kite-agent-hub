defmodule KiteAgentHubWeb.API.CollectiveIntelligenceControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Orgs, Repo}

  defp auth(conn, agent), do: put_req_header(conn, "authorization", "Bearer " <> agent.api_token)

  describe "GET /api/v1/collective-intelligence" do
    test "403s with reciprocity message when workspace has not opted in", %{conn: conn} do
      %{agent: agent} = trading_scope_fixture()

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> get(~p"/api/v1/collective-intelligence")
        |> json_response(403)

      assert resp["ok"] == false
      assert resp["error"] == "kci_not_enabled"
      assert resp["message"] =~ "Settings"
      assert resp["message"] =~ "contribute"
      assert is_binary(resp["consent_version"])
    end

    test "returns enabled summary for opted-in workspaces", %{conn: conn} do
      %{user: user, org: org, agent: agent} = trading_scope_fixture()
      assert {:ok, _org} = Orgs.update_collective_intelligence(user, org.id, true)

      resp =
        conn
        |> auth(Repo.reload!(agent))
        |> get(~p"/api/v1/collective-intelligence")
        |> json_response(200)

      assert resp["collective_intelligence"]["enabled"] == true
      assert resp["collective_intelligence"]["name"] == "Kite Collective Intelligence"
    end
  end

  defp trading_scope_fixture do
    agent_scope_fixture(%{
      agent_type: "trading",
      wallet_address: "0x0000000000000000000000000000000000000001"
    })
  end
end
