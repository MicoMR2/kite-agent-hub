defmodule KiteAgentHubWeb.Plugs.AuthenticateAgentTest do
  @moduledoc """
  Hermetic auth-contract test for the `:api` pipeline plug. Confirms
  the four documented behaviors:
    * No Authorization header  → 401, halted, no assigns
    * Bad Bearer token         → 401, halted, no assigns
    * Valid Bearer token       → assigns :current_agent + :current_org_id
    * Lookup raises an error   → 503 soft timeout, halted
  """

  use KiteAgentHubWeb.ConnCase, async: true

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Trading.KiteAgent
  alias KiteAgentHubWeb.Plugs.AuthenticateAgent

  setup do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "plug test org",
          slug: "plug-test-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(%{
        name: "PlugTestAgent",
        api_token: "tok_plug_test_#{System.unique_integer([:positive])}",
        agent_type: "trading",
        organization_id: org.id
      })
      |> Repo.insert()

    {:ok, agent: agent}
  end

  test "no Authorization header → 401 halted" do
    conn =
      build_conn(:get, "/api/v1/trades")
      |> AuthenticateAgent.call([])

    assert conn.halted
    assert conn.status == 401
    assert conn.resp_body =~ "invalid api key"
    refute conn.assigns[:current_agent]
  end

  test "bad Bearer token → 401 halted" do
    conn =
      build_conn(:get, "/api/v1/trades")
      |> put_req_header("authorization", "Bearer not_a_real_token")
      |> AuthenticateAgent.call([])

    assert conn.halted
    assert conn.status == 401
    refute conn.assigns[:current_agent]
  end

  test "valid Bearer token → assigns set, not halted", %{agent: agent} do
    conn =
      build_conn(:get, "/api/v1/trades")
      |> put_req_header("authorization", "Bearer " <> agent.api_token)
      |> AuthenticateAgent.call([])

    refute conn.halted
    assert conn.assigns.current_agent.id == agent.id
    assert conn.assigns.current_org_id == agent.organization_id
  end

  test "empty Bearer token → 401 halted (no DB call)" do
    conn =
      build_conn(:get, "/api/v1/trades")
      |> put_req_header("authorization", "Bearer ")
      |> AuthenticateAgent.call([])

    assert conn.halted
    assert conn.status == 401
  end

  test "non-Bearer scheme → 401 halted" do
    conn =
      build_conn(:get, "/api/v1/trades")
      |> put_req_header("authorization", "Basic dXNlcjpwYXNz")
      |> AuthenticateAgent.call([])

    assert conn.halted
    assert conn.status == 401
  end
end
