defmodule KiteAgentHub.Trading.DrawdownGate do
  @moduledoc """
  User-configured drawdown circuit breaker. KAH executes the user's
  pre-set rule on incoming `POST /api/v1/trades` requests — it does
  NOT impose its own thresholds.

  ## Legal framing

  Platform-defined trade-blocking thresholds would be KAH exercising
  investment discretion on a user's brokerage account (broker-dealer /
  RIA territory). User-defined thresholds enforced by the platform are
  closer to a broker honoring a user's stop-loss — the user makes the
  risk decision, KAH just executes their pre-set rule. That keeps us
  on the SaaS tooling side of the line.

  Two thresholds, both nullable on `kite_agents`:
    * `halt_at_dd_pct` — when today's DD% breaches this, new entries
      are blocked
    * `flatten_at_dd_pct` — when breached, all open positions are
      closed (Phase 2 — Phase 1 only halts, no flatten worker yet)

  Both default to `nil` (disabled). The most common path through
  `check_or_reject/2` is "no thresholds set → :ok immediately, no
  broker call attempted." That keeps the latency hit on agents who
  have NOT opted in to zero.

  ## DD calculation

  ```
  dd_pct = (today_realized_pnl + open_unrealized_pnl) / starting_nav_today
  ```

  * `today_realized_pnl` from the `trades` table — exact, no broker hop
  * `open_unrealized_pnl` from the broker's `/positions` endpoint
  * `starting_nav_today` from the broker's account summary

  Phase 1 covers Alpaca-only unrealized P&L. OANDA + Kalshi positions
  are NOT included in the unrealized calc this sprint — they ship in
  Phase 2 alongside the flatten worker. An agent trading exclusively
  on OANDA in Phase 1 will have unrealized P&L from their OANDA
  positions excluded; the 422 response surfaces this so the user
  understands the limitation.

  ## Failure mode

  * Broker reachable + DD breach → `{:error, :daily_drawdown_halt}`,
    audit `action="blocked"`. **Fail-closed** on a confirmed breach.
  * Broker reachable + DD under threshold → `:ok`, audit
    `action="allowed"`.
  * Broker timeout / connectivity error → `:ok`, audit
    `action="skipped"`. **Fail-open** on a connectivity blip — the
    user's broker is the authoritative risk gate, and denying their
    trade because KAH can't reach the broker is worse UX than missing
    a DD check the broker would catch anyway.
  """

  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{DdAuditLog, KiteAgent}

  @broker_timeout_ms 2_000

  @doc """
  Check the agent's current DD against their configured thresholds.
  Returns `:ok` to allow the trade, or `{:error, :daily_drawdown_halt,
  reason_string}` to block it.

  The `reason_string` is intended to be surfaced to the user — it
  includes the user's own configured threshold and the Phase 1
  limitation note about OANDA/Kalshi unrealized exclusion.

  Most agents have no thresholds set; this returns `:ok` without a
  broker call in that case.
  """
  @spec check_or_reject(KiteAgent.t()) ::
          :ok | {:error, :daily_drawdown_halt, String.t()}
  def check_or_reject(%KiteAgent{halt_at_dd_pct: nil, flatten_at_dd_pct: nil}) do
    :ok
  end

  def check_or_reject(%KiteAgent{} = agent) do
    # Phase 1a ships the data + plumbing layer only. Real broker NAV
    # fetch + realized-P&L DD math arrive in Phase 1b (very next PR).
    # Until then, every check on an opt-in agent records a `skipped`
    # audit row so the audit log accumulates and operators can see
    # the gate is plumbed end-to-end. The reason string is documented
    # so future audit-log readers can distinguish "Phase 1a pending"
    # from "Phase 1b broker timeout" cleanly (CyberSec ask 14168).
    write_audit(
      agent,
      agent.halt_at_dd_pct,
      nil,
      nil,
      "skipped",
      "enforcement_not_active_phase_1b_pending"
    )

    :ok
  end

  defp write_audit(agent, threshold_value, equity, dd_pct, action, reason) do
    %DdAuditLog{}
    |> DdAuditLog.changeset(%{
      kite_agent_id: agent.id,
      threshold_type: "halt",
      threshold_value: threshold_value,
      equity: equity,
      dd_pct: dd_pct,
      action: action,
      reason: reason
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "DrawdownGate: audit log insert failed for agent #{agent.id}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  @doc false
  def broker_timeout_ms, do: @broker_timeout_ms
end
