defmodule KiteAgentHub.Trading.DrawdownGateTest do
  @moduledoc """
  Hermetic test for the Phase 1a plumbing.

  Phase 1a does NOT compute DD% or block trades — the gate is wired
  into the trade controller and writes audit rows but every opt-in
  agent gets `:ok` with a `skipped` audit row carrying the
  `enforcement_not_active_phase_1b_pending` reason. Phase 1b adds
  real broker NAV fetch + realized-P&L math and flips this to
  fail-closed on confirmed breaches.

  These tests pin the 1a contract so 1b can be reviewed against a
  clear behavioral baseline.
  """

  use KiteAgentHub.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{DdAuditLog, DrawdownGate, KiteAgent}

  defp make_agent(opts \\ []) do
    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "dd-gate-test",
          slug: "dd-gate-#{System.unique_integer([:positive])}"
        })
      )

    attrs =
      %{
        name: "DdGateAgent",
        api_token: "tok_dd_#{System.unique_integer([:positive])}",
        agent_type: "trading",
        organization_id: org.id
      }
      |> Map.merge(Map.new(opts))

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(attrs)
      |> Repo.insert()

    agent
  end

  defp audit_rows_for(agent) do
    Repo.all(from a in DdAuditLog, where: a.kite_agent_id == ^agent.id)
  end

  test "no thresholds set → :ok and no audit row" do
    agent = make_agent()

    assert :ok = DrawdownGate.check_or_reject(agent)
    assert audit_rows_for(agent) == []
  end

  test "halt threshold set → :ok with phase_1b_pending audit row" do
    agent = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))

    assert :ok = DrawdownGate.check_or_reject(agent)

    [row] = audit_rows_for(agent)
    assert row.threshold_type == "halt"
    assert Decimal.equal?(row.threshold_value, Decimal.new("-3.0"))
    assert row.action == "skipped"
    assert row.reason == "enforcement_not_active_phase_1b_pending"
    assert is_nil(row.dd_pct)
    assert is_nil(row.equity)
  end

  test "flatten threshold set (no halt) → also skipped audit row" do
    agent = make_agent(flatten_at_dd_pct: Decimal.new("-5.0"))

    assert :ok = DrawdownGate.check_or_reject(agent)

    [row] = audit_rows_for(agent)
    assert row.action == "skipped"
    assert row.reason == "enforcement_not_active_phase_1b_pending"
  end

  test "audit rows scope by agent_id — agent A check doesn't leak into agent B" do
    agent_a = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))
    agent_b = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))

    assert :ok = DrawdownGate.check_or_reject(agent_a)

    assert length(audit_rows_for(agent_a)) == 1
    assert audit_rows_for(agent_b) == []
  end
end
