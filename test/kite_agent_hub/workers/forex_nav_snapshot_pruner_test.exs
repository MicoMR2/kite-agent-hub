defmodule KiteAgentHub.Workers.ForexNavSnapshotPrunerTest do
  use KiteAgentHub.DataCase, async: false
  use Oban.Testing, repo: KiteAgentHub.Repo

  alias KiteAgentHub.Forex.NavSnapshot
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.KiteAgent
  alias KiteAgentHub.Workers.ForexNavSnapshotPruner

  defp make_agent do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "pruner-test",
          slug: "pruner-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(%{
        name: "PrunerAgent",
        api_token: "tok_pruner_#{System.unique_integer([:positive])}",
        agent_type: "trading",
        organization_id: org.id
      })
      |> Repo.insert()

    agent
  end

  defp insert_sample(agent, days_ago) do
    ts = System.system_time(:second) - days_ago * 86_400

    inserted_at =
      DateTime.utc_now()
      |> DateTime.add(-days_ago, :day)
      |> DateTime.truncate(:second)

    {:ok, snap} =
      Repo.insert(%NavSnapshot{
        kite_agent_id: agent.id,
        ts: ts,
        nav: 1000.0 + days_ago,
        inserted_at: inserted_at
      })

    snap
  end

  test "perform/1 deletes snapshots older than @max_age_days and keeps fresh ones" do
    agent = make_agent()

    fresh = insert_sample(agent, 0)
    mid = insert_sample(agent, 29)
    just_old = insert_sample(agent, 31)
    ancient = insert_sample(agent, 365)

    assert :ok = perform_job(ForexNavSnapshotPruner, %{})

    remaining_ids =
      NavSnapshot
      |> Repo.all()
      |> Enum.map(& &1.id)

    assert fresh.id in remaining_ids
    assert mid.id in remaining_ids
    refute just_old.id in remaining_ids
    refute ancient.id in remaining_ids
  end

  test "perform/1 is safe on an empty table" do
    assert :ok = perform_job(ForexNavSnapshotPruner, %{})
  end
end
