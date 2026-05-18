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
    case compute_dd(agent) do
      {:ok, dd_pct, equity} ->
        evaluate_halt(agent, dd_pct, equity)

      {:error, :no_alpaca_credentials} ->
        write_audit(
          agent,
          agent.halt_at_dd_pct,
          nil,
          nil,
          "skipped",
          "no_alpaca_credentials_phase_1b"
        )

        :ok

      {:error, reason} ->
        write_audit(
          agent,
          agent.halt_at_dd_pct,
          nil,
          nil,
          "skipped",
          "broker_error: #{inspect(reason)}"
        )

        Logger.warning(
          "DrawdownGate: skipping DD check for agent #{agent.id} — broker error: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp evaluate_halt(%KiteAgent{halt_at_dd_pct: nil} = agent, dd_pct, equity) do
    # Halt is opt-out for this agent, but flatten may still be set —
    # evaluate it independently so a user who set ONLY a flatten
    # threshold still gets the unwind behavior they configured.
    flatten_note = maybe_trigger_flatten(agent, dd_pct, equity)
    write_audit(agent, "halt", nil, equity, dd_pct, "allowed", flatten_note)
    :ok
  end

  defp evaluate_halt(%KiteAgent{} = agent, dd_pct, equity) do
    threshold = Decimal.to_float(agent.halt_at_dd_pct)

    if dd_pct <= threshold do
      flatten_note = maybe_trigger_flatten(agent, dd_pct, equity)

      write_audit(
        agent,
        "halt",
        agent.halt_at_dd_pct,
        equity,
        dd_pct,
        "blocked",
        flatten_note
      )

      reason =
        "user-configured halt at #{threshold}% — current daily DD #{Float.round(dd_pct, 2)}%. " <>
          "Note: Phase 2c covers Alpaca realized + unrealized P&L vs Alpaca last_equity. " <>
          "OANDA/Kalshi positions will be included in Phase 2d." <>
          flatten_suffix(flatten_note)

      {:error, :daily_drawdown_halt, reason}
    else
      flatten_note = maybe_trigger_flatten(agent, dd_pct, equity)
      write_audit(agent, "halt", agent.halt_at_dd_pct, equity, dd_pct, "allowed", flatten_note)
      :ok
    end
  end

  # When the user-configured `flatten_at_dd_pct` is set AND today's
  # DD breaches it, write a `threshold_type="flatten"` audit row and
  # schedule the `FlattenWorker` (Oban-deduped to one job per agent
  # per day). Returns a short status string the caller can append to
  # the audit reason / 422 message so the user sees it surfaced.
  #
  # Per CyberSec ask 14209 #3: phrase the surfaced copy as
  # "scheduled" not "enqueued" so we don't promise the close
  # definitively if Oban.insert ever errors.
  defp maybe_trigger_flatten(%KiteAgent{flatten_at_dd_pct: nil}, _dd_pct, _equity), do: nil

  defp maybe_trigger_flatten(%KiteAgent{} = agent, dd_pct, equity) do
    threshold = Decimal.to_float(agent.flatten_at_dd_pct)

    if dd_pct <= threshold do
      case schedule_flatten(agent, threshold) do
        {:ok, _job} ->
          write_audit(
            agent,
            "flatten",
            agent.flatten_at_dd_pct,
            equity,
            dd_pct,
            "blocked",
            "Flatten worker scheduled — user-configured flatten at #{threshold}% breached at #{Float.round(dd_pct, 2)}%"
          )

          " Flatten worker scheduled."

        {:error, reason} ->
          # Oban insert failed (DB blip or duplicate within the 24h
          # unique window). The user still gets the halt 422; we just
          # don't promise the flatten in copy. Audit captures the
          # attempt either way.
          Logger.warning(
            "DrawdownGate: flatten enqueue failed for agent #{agent.id}: #{inspect(reason)}"
          )

          write_audit(
            agent,
            "flatten",
            agent.flatten_at_dd_pct,
            equity,
            dd_pct,
            "skipped",
            "flatten_enqueue_failed: #{inspect(reason)}"
          )

          nil
      end
    end
  end

  defp schedule_flatten(%KiteAgent{} = agent, threshold) do
    %{
      "agent_id" => agent.id,
      "reason" => "daily_dd_flatten",
      "threshold_pct" => threshold
    }
    |> KiteAgentHub.Workers.FlattenWorker.new()
    |> Oban.insert()
  rescue
    e ->
      {:error, Exception.message(e)}
  end

  defp flatten_suffix(nil), do: ""
  defp flatten_suffix(suffix) when is_binary(suffix), do: suffix

  # Phase 1b: realized-P&L DD against Alpaca's `last_equity` baseline.
  # Unrealized P&L from open positions is NOT included yet — that ships
  # in Phase 2 alongside the flatten worker. Multi-platform agents
  # (OANDA, Kalshi) without Alpaca creds skip with a clear reason so
  # the audit log distinguishes "no creds" from "broker timeout".
  defp compute_dd(%KiteAgent{} = agent) do
    case KiteAgentHub.Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
      {:error, :not_configured} ->
        {:error, :no_alpaca_credentials}

      {:error, reason} ->
        {:error, reason}

      {:ok, {key_id, secret, env}} ->
        fetch_and_compute(agent, key_id, secret, env)
    end
  end

  defp fetch_and_compute(agent, key_id, secret, env) do
    # Phase 2c: account NAV + positions list now run in parallel
    # under a single shared `@broker_timeout_ms` deadline. Sequential
    # `Task.yield` calls would have stacked the budget to 2 ×
    # @broker_timeout_ms; computing one wall-clock deadline up front
    # and re-deriving "remaining" for each yield keeps total wall
    # time bounded (CyberSec ask 14230 #1).
    deadline = System.monotonic_time(:millisecond) + @broker_timeout_ms

    account_task =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        KiteAgentHub.TradingPlatforms.AlpacaClient.account(key_id, secret, env)
      end)

    positions_task =
      Task.Supervisor.async_nolink(KiteAgentHub.TaskSupervisor, fn ->
        KiteAgentHub.TradingPlatforms.AlpacaClient.positions(key_id, secret, env)
      end)

    with {:ok, %{last_equity: nav}} when is_float(nav) and nav > 0 <-
           yield_with_deadline(account_task, deadline),
         {:ok, positions} when is_list(positions) <-
           yield_with_deadline(positions_task, deadline) do
      compute_dd_from_broker_data(agent, nav, unrealized_total(positions))
    else
      :timeout ->
        {:error, :alpaca_timeout}

      {:ok, _account_without_nav} ->
        {:error, :alpaca_nav_missing}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected, other}}
    end
  end

  # Wait on `task` until the shared deadline is reached; on timeout
  # we brutally shut it down so the supervisor doesn't leak. Returns
  # the inner client result (`{:ok, ...} | {:error, ...}`) or the
  # bare `:timeout` atom.
  defp yield_with_deadline(task, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:task_exit, reason}}
      nil -> :timeout
    end
  end

  defp unrealized_total(positions) when is_list(positions) do
    Enum.reduce(positions, 0.0, fn p, acc ->
      case Map.get(p, :unrealized_pl) do
        n when is_number(n) -> acc + n
        _ -> acc
      end
    end)
  end

  @doc """
  Phase 2c math, exposed so tests can pin the formula without a live
  Alpaca round-trip. Combines today's realized P&L (closed trades
  settled today UTC) with the broker-reported unrealized P&L on open
  positions, expressed as a percentage of the broker's `last_equity`
  baseline.
  """
  @spec compute_dd_from_broker_data(KiteAgent.t(), float(), float()) ::
          {:ok, float(), float()}
  def compute_dd_from_broker_data(%KiteAgent{} = agent, nav, unrealized_pl)
      when is_float(nav) and nav > 0 and is_float(unrealized_pl) do
    realized =
      agent.id
      |> KiteAgentHub.Trading.today_realized_pnl_for_agent()
      |> Decimal.to_float()

    dd_pct = (realized + unrealized_pl) / nav * 100.0
    {:ok, dd_pct, nav}
  end

  defp write_audit(agent, threshold_value, equity, dd_pct, action, reason) do
    write_audit(agent, "halt", threshold_value, equity, dd_pct, action, reason)
  end

  defp write_audit(agent, threshold_type, threshold_value, equity, dd_pct, action, reason) do
    %DdAuditLog{}
    |> DdAuditLog.changeset(%{
      kite_agent_id: agent.id,
      threshold_type: threshold_type,
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
