defmodule KiteAgentHub.Forex.NavHistoryTest do
  @moduledoc """
  Hermetic test for the persistent NAV backing of the Forex tab
  Session NAV sparkline. Confirms:
    * `record_sample/3` round-trips a single `{ts, nav}` row
    * `recent_for_agent/2` returns newest-first to match the
      in-memory ring buffer shape
    * Cross-agent scope holds — calling with agent A never returns
      agent B's rows
    * `:limit` caps the result set
  """

  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Forex.NavHistory
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.KiteAgent

  defp make_agent(suffix) do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "nav-history-test-#{suffix}",
          slug: "nav-history-#{suffix}-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(%{
        name: "NavTestAgent#{suffix}",
        api_token: "tok_nav_#{suffix}_#{System.unique_integer([:positive])}",
        agent_type: "trading",
        organization_id: org.id
      })
      |> Repo.insert()

    agent
  end

  test "record_sample/3 + recent_for_agent/2 round-trip a single sample" do
    agent = make_agent("a")
    ts = System.system_time(:second)

    assert {:ok, _} = NavHistory.record_sample(agent.id, ts, 1000.0)
    assert [{^ts, 1000.0}] = NavHistory.recent_for_agent(agent.id)
  end

  test "recent_for_agent/2 returns newest-first" do
    agent = make_agent("b")
    base = System.system_time(:second)

    {:ok, _} = NavHistory.record_sample(agent.id, base - 30, 1000.0)
    {:ok, _} = NavHistory.record_sample(agent.id, base, 1010.0)
    {:ok, _} = NavHistory.record_sample(agent.id, base - 60, 990.0)

    samples = NavHistory.recent_for_agent(agent.id)

    assert [
             {^base, 1010.0},
             {ts1, 1000.0},
             {ts2, 990.0}
           ] = samples

    assert ts1 == base - 30
    assert ts2 == base - 60
  end

  test "recent_for_agent/2 scopes by agent_id — no cross-agent leak" do
    agent_a = make_agent("c")
    agent_b = make_agent("d")
    ts = System.system_time(:second)

    {:ok, _} = NavHistory.record_sample(agent_a.id, ts, 100.0)
    {:ok, _} = NavHistory.record_sample(agent_b.id, ts, 200.0)

    assert NavHistory.recent_for_agent(agent_a.id) == [{ts, 100.0}]
    assert NavHistory.recent_for_agent(agent_b.id) == [{ts, 200.0}]
  end

  test "recent_for_agent/2 honors :limit" do
    agent = make_agent("e")
    base = System.system_time(:second)

    for i <- 1..5 do
      {:ok, _} = NavHistory.record_sample(agent.id, base - i, 100.0 + i)
    end

    assert length(NavHistory.recent_for_agent(agent.id, limit: 3)) == 3
    assert length(NavHistory.recent_for_agent(agent.id, limit: 10)) == 5
  end
end
