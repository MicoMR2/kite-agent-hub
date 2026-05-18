defmodule KiteAgentHub.Workers.FlattenWorkerTest do
  @moduledoc """
  Phase 2b hermetic tests for `KiteAgentHub.Workers.FlattenWorker`.
  Pins the three CyberSec-flagged safety guards (msg 14209 + the
  follow-up CLEAR-hold ask):

    1. Enqueue contract — the worker accepts the documented args shape
    2. Uniqueness — `unique: [period: 86_400, keys: [:agent_id]]`
       dedupes within 24h so a flatten can't be doubled up
    3. Stale-rule guard — `perform/1` re-fetches the agent and bails
       if `flatten_at_dd_pct` has been cleared between enqueue and
       execution
  """

  use KiteAgentHub.DataCase, async: false
  use Oban.Testing, repo: KiteAgentHub.Repo

  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{DdAuditLog, KiteAgent}
  alias KiteAgentHub.Workers.FlattenWorker

  import Ecto.Query, only: [from: 2]

  defp make_agent(opts) do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "flatten-worker-test",
          slug: "flatten-#{System.unique_integer([:positive])}"
        })
      )

    attrs =
      Map.merge(
        %{
          name: "FlattenAgent",
          api_token: "tok_flatten_#{System.unique_integer([:positive])}",
          agent_type: "trading",
          organization_id: org.id
        },
        Map.new(opts)
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(attrs)
      |> Repo.insert()

    agent
  end

  defp audit_rows_for(agent) do
    Repo.all(from a in DdAuditLog, where: a.kite_agent_id == ^agent.id)
  end

  describe "worker configuration (CyberSec ask 14209 #1)" do
    test "FlattenWorker.new builds a valid changeset with the documented args" do
      agent = make_agent(flatten_at_dd_pct: Decimal.new("-5.0"))

      args = %{
        "agent_id" => agent.id,
        "reason" => "daily_dd_flatten",
        "threshold_pct" => -5.0
      }

      changeset = FlattenWorker.new(args)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :worker) == "KiteAgentHub.Workers.FlattenWorker"
      assert Ecto.Changeset.get_change(changeset, :queue) == "trade_execution"
      assert Ecto.Changeset.get_change(changeset, :args) == args
    end

    test "worker advertises 24h agent-scoped uniqueness (Oban-level dedupe)" do
      # The uniqueness configuration is baked into the worker module
      # via `use Oban.Worker, unique: [...]`. Asserting the merged
      # opts here pins the contract — if a future change to the
      # worker drops or weakens the unique clause, this test fails
      # before reaching prod.
      opts = FlattenWorker.__opts__()

      assert opts[:unique][:period] == 86_400
      assert opts[:unique][:fields] == [:args]
      assert opts[:unique][:keys] == [:agent_id]
    end
  end

  describe "stale-rule guard (CyberSec ask 14209 #1 stale-rule)" do
    test "perform/1 skips and writes no audit when flatten_at_dd_pct has been cleared" do
      # Agent had a threshold when the job enqueued, but the user
      # cleared it before the worker ran. `perform/1` MUST NOT close
      # positions on a stale rule.
      agent = make_agent(flatten_at_dd_pct: nil)

      assert :ok =
               perform_job(FlattenWorker, %{
                 "agent_id" => agent.id,
                 "reason" => "daily_dd_flatten",
                 "threshold_pct" => -5.0
               })

      assert audit_rows_for(agent) == []
    end

    test "perform/1 skips when the agent record no longer exists" do
      # Job was scheduled for an agent that has since been deleted.
      # Worker must log + return :ok instead of crashing.
      missing_agent_id = Ecto.UUID.generate()

      assert :ok =
               perform_job(FlattenWorker, %{
                 "agent_id" => missing_agent_id,
                 "reason" => "daily_dd_flatten",
                 "threshold_pct" => -5.0
               })
    end

    test "perform/1 with threshold still set but no Alpaca creds skips Alpaca path" do
      # Multi-platform agents without Alpaca creds aren't flattened
      # in Phase 2b. Worker returns :ok with no audit rows because
      # there are no positions to close — same as the empty-broker case.
      agent = make_agent(flatten_at_dd_pct: Decimal.new("-5.0"))

      assert :ok =
               perform_job(FlattenWorker, %{
                 "agent_id" => agent.id,
                 "reason" => "daily_dd_flatten",
                 "threshold_pct" => -5.0
               })

      assert audit_rows_for(agent) == []
    end
  end
end
