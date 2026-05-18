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

  test "halt threshold set + no Alpaca creds → skipped audit with no_alpaca reason" do
    # Phase 1b: opt-in agents without Alpaca credentials skip the
    # check with a distinct reason so the audit log is clear about
    # why (vs broker timeout, vs no-op-by-design Phase 1a).
    agent = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))

    assert :ok = DrawdownGate.check_or_reject(agent)

    [row] = audit_rows_for(agent)
    assert row.threshold_type == "halt"
    assert Decimal.equal?(row.threshold_value, Decimal.new("-3.0"))
    assert row.action == "skipped"
    assert row.reason == "no_alpaca_credentials_phase_1b"
    assert is_nil(row.dd_pct)
    assert is_nil(row.equity)
  end

  test "flatten threshold set (no halt) + no creds → also skipped audit row" do
    agent = make_agent(flatten_at_dd_pct: Decimal.new("-5.0"))

    assert :ok = DrawdownGate.check_or_reject(agent)

    [row] = audit_rows_for(agent)
    assert row.action == "skipped"
    assert row.reason == "no_alpaca_credentials_phase_1b"
  end

  test "audit rows scope by agent_id — agent A check doesn't leak into agent B" do
    agent_a = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))
    agent_b = make_agent(halt_at_dd_pct: Decimal.new("-3.0"))

    assert :ok = DrawdownGate.check_or_reject(agent_a)

    assert length(audit_rows_for(agent_a)) == 1
    assert audit_rows_for(agent_b) == []
  end

  describe "today_realized_pnl_for_agent/1" do
    alias KiteAgentHub.Trading
    alias KiteAgentHub.Trading.TradeRecord

    test "sums settled realized_pnl only for trades that settled today (UTC)" do
      agent = make_agent()

      # Two settled trades today + one open trade. Only the settled
      # ones with realized_pnl contribute to the sum.
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, t1} =
        Repo.insert(%TradeRecord{
          kite_agent_id: agent.id,
          market: "AAPL",
          side: "long",
          action: "sell",
          contracts: Decimal.new("10"),
          fill_price: Decimal.new("100.00"),
          status: "settled",
          realized_pnl: Decimal.new("12.50"),
          updated_at: now,
          inserted_at: now
        })

      {:ok, _t2} =
        Repo.insert(%TradeRecord{
          kite_agent_id: agent.id,
          market: "MSFT",
          side: "long",
          action: "sell",
          contracts: Decimal.new("5"),
          fill_price: Decimal.new("250.00"),
          status: "settled",
          realized_pnl: Decimal.new("-7.25"),
          updated_at: now,
          inserted_at: now
        })

      {:ok, _t3_open} =
        Repo.insert(%TradeRecord{
          kite_agent_id: agent.id,
          market: "TSLA",
          side: "long",
          action: "buy",
          contracts: Decimal.new("3"),
          fill_price: Decimal.new("300.00"),
          status: "open",
          realized_pnl: nil,
          updated_at: now,
          inserted_at: now
        })

      total = Trading.today_realized_pnl_for_agent(agent.id)

      assert Decimal.equal?(total, Decimal.new("5.25"))
      # Sanity: trade rows did make it in.
      assert Repo.get(TradeRecord, t1.id)
    end

    test "returns 0 when no trades settled today" do
      agent = make_agent()
      assert Decimal.equal?(Trading.today_realized_pnl_for_agent(agent.id), Decimal.new(0))
    end

    test "scopes by agent_id — agent A's settled P&L doesn't leak into B" do
      agent_a = make_agent()
      agent_b = make_agent()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, _} =
        Repo.insert(%TradeRecord{
          kite_agent_id: agent_a.id,
          market: "AAPL",
          side: "long",
          action: "sell",
          contracts: Decimal.new("10"),
          fill_price: Decimal.new("150.00"),
          status: "settled",
          realized_pnl: Decimal.new("100.00"),
          updated_at: now,
          inserted_at: now
        })

      assert Decimal.equal?(Trading.today_realized_pnl_for_agent(agent_a.id), Decimal.new("100.00"))
      assert Decimal.equal?(Trading.today_realized_pnl_for_agent(agent_b.id), Decimal.new(0))
    end
  end
end
