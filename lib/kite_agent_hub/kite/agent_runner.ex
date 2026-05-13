defmodule KiteAgentHub.Kite.AgentRunner do
  @moduledoc """
  GenServer that drives a single Kite agent through the signal → execute loop.

  Start one per active agent:

      KiteAgentHub.Kite.AgentRunner.start_link(%{agent_id: agent.id, interval_ms: 60_000})

  Every `interval_ms` (default 60s) it:
  1. Reloads the agent — stops itself if agent is no longer active.
  2. Runs the rule-based exit pass (DB: reads edge scores / open trades).
  3. Builds a market context snapshot (DB: reads trade counts).
  4. **Releases the DB connection** — the `Repo.with_user` block ends here.
  5. Calls SignalEngine.generate/2 with the context (LLM HTTP call).
  6. If {:ok, signal} — enqueues a TradeExecutionWorker job via Oban.
  7. If {:hold, _}   — logs and waits for the next tick.
  8. Enqueues a PositionSyncWorker on every tick to keep settlements current.

  ## DB pool design

  The original code ran the entire cycle — including the LLM call — inside
  `Repo.with_user/2`. That held a DB connection for the full LLM round-trip
  (~1-5 seconds per agent). With N active agents all ticking together, the
  pool of `pool_size` connections was exhausted by tick N+1, causing
  `DBConnection.ConnectionError` cascades that restarted the GenServers and
  hammered the pool further.

  The fix is a two-phase split:

  **Phase 1 — DB phase** (`Repo.with_user` block):
    - Load agent, check status.
    - Run rule-based exit pass (needs RLS-scoped edge scores).
    - Build context map (needs RLS-scoped trade counts / open trades).
    - Returns `{:ok, {agent, context}}` or `{:ok, :stop}`.

  **Phase 2 — LLM phase** (after the block, no DB connection held):
    - `SignalEngine.generate(agent, context)` — external HTTP, may take seconds.
    - `Oban.insert` for TradeExecutionWorker — uses its own short-lived connection.
    - `Oban.insert` for PositionSyncWorker — same.

  `Oban.insert` does need a DB connection but only for a ~1ms INSERT, not a
  multi-second LLM call, so we move those outside `Repo.with_user` too.

  ## AgentLog integration

  Every key event (tick start, rule-based scan/exits/crash, signal trade/hold/error)
  pushes a structured entry to `KiteAgentHub.Kite.AgentLog`. The dashboard's
  Agent Logs tab subscribes to the per-agent topic and renders entries live so
  operators can watch what each agent is doing without grepping server logs.

  The runner is supervised by AgentRunnerSupervisor.
  """

  use GenServer, restart: :transient

  require Logger

  alias KiteAgentHub.{Trading, Repo}

  alias KiteAgentHub.Kite.{
    AgentLog,
    RPC,
    SignalEngine,
    PriceOracle,
    RuleBasedStrategy,
    PortfolioEdgeScorer
  }

  alias KiteAgentHub.Workers.{TradeExecutionWorker, PositionSyncWorker}

  @default_interval_ms 60_000

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    GenServer.start_link(__MODULE__, opts, name: via(agent_id))
  end

  def stop(agent_id) do
    case Registry.lookup(KiteAgentHub.AgentRegistry, agent_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :not_running
    end
  end

  def running?(agent_id) do
    case Registry.lookup(KiteAgentHub.AgentRegistry, agent_id) do
      [{_, _}] -> true
      [] -> false
    end
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    # owner_user_id may be passed in directly (from supervisor at boot) or resolved lazily on first tick
    owner_user_id = Keyword.get(opts, :owner_user_id)

    Logger.info("AgentRunner: starting for agent #{agent_id}, interval #{interval}ms")

    send(self(), :tick)

    {:ok, %{agent_id: agent_id, interval_ms: interval, owner_user_id: owner_user_id}}
  end

  @impl true
  def handle_info(
        :tick,
        %{agent_id: agent_id, interval_ms: interval, owner_user_id: owner_user_id} = state
      ) do
    # ── Phase 1: DB phase ───────────────────────────────────────────────────────
    # Run everything that needs a RLS-scoped DB connection inside a single
    # Repo.with_user block. The block returns either:
    #   {:ok, :stop}                  — agent deactivated; stop the GenServer
    #   {:ok, {:run, agent, context, rule_actions}} — proceed to LLM phase
    #
    # The block ENDS before the LLM call so the connection is released promptly.
    db_result =
      try do
        Repo.with_user(owner_user_id, fn ->
          agent = Trading.get_agent!(agent_id)

          if agent.status != "active" do
            Logger.info("AgentRunner: agent #{agent_id} is #{agent.status}, stopping runner")
            :stop
          else
            # Build only the DB-backed slice of the context inside the
            # transaction. The HTTP-backed slice (RPC + PriceOracle)
            # runs in Phase 2 — see build_remote_context/2.
            db_ctx = build_db_context(agent)
            # Pre-compute the rule-based exit threshold from settled
            # PnL stats. Pure DB, needs RLS scope; the broker HTTP
            # scoring that previously wrapped this lives in Phase 2
            # via PortfolioEdgeScorer.score_portfolio_split/2.
            threshold = RuleBasedStrategy.exit_threshold_for(agent)
            {:run, agent, db_ctx, threshold}
          end
        end)
      rescue
        e in DBConnection.ConnectionError ->
          Logger.warning(
            "AgentRunner: agent #{agent_id} tick deferred — DB pool busy: #{Exception.message(e)}"
          )

          {:error, :db_pool_busy}

        e ->
          Logger.error("AgentRunner: agent #{agent_id} tick raised: #{Exception.message(e)}")

          {:error, :exception}
      end

    # ── Phase 2: LLM + enqueue phase (no DB connection held) ───────────────────
    result =
      case db_result do
        {:ok, :stop} ->
          {:ok, :stop}

        {:ok, {:run, agent, db_ctx, threshold}} ->
          # DB connection is released. Run the slow HTTP calls (RPC,
          # PriceOracle, broker positions) and the LLM round-trip in
          # Phase 2 — none of them holds a Repo connection.
          remote_ctx = build_remote_context(agent, db_ctx)
          context = Map.merge(db_ctx, remote_ctx)
          rule_actions = build_rule_actions(agent, threshold, owner_user_id)
          run_post_db_phase(agent, context, rule_actions, owner_user_id)
          {:ok, :continue}

        {:error, _} = err ->
          err
      end

    case result do
      {:ok, :stop} ->
        {:stop, :normal, state}

      {:ok, :continue} ->
        schedule_tick(interval)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("AgentRunner: tick failed for agent #{agent_id}: #{inspect(reason)}")
        schedule_tick(interval)
        {:noreply, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Collect rule-based exit actions in Phase 2 (no Repo connection
  # held). `PortfolioEdgeScorer.score_portfolio_split/2` keeps the
  # credentials read inside its own brief `with_user`, then runs the
  # broker HTTP fan-out outside the lock. `RuleBasedStrategy.plan_with/3`
  # is pure (no DB) — the threshold was pre-computed in Phase 1.
  # Crashes are caught so a buggy edge-scorer does not take down the
  # whole runner.
  defp build_rule_actions(agent, threshold, owner_user_id) do
    if auto_exit_eligible?(agent) do
      scores = PortfolioEdgeScorer.score_portfolio_split(agent.organization_id, owner_user_id)
      RuleBasedStrategy.plan_with(agent, scores, threshold)
    else
      # Auto-exit opt-in is server-side. Default is `false`, so the
      # rule-based pass is a no-op unless the user has explicitly
      # toggled `risk_config.auto_exit_enabled` on (and the agent is
      # a trading agent — research / conversational agents have no
      # broker path so the toggle is meaningless and rejected by
      # `KiteAgent.risk_config_changeset/2`). Skipping the
      # `score_portfolio_split` call here also saves the broker HTTP
      # round-trip on agents that don't want auto-exits.
      []
    end
  rescue
    e ->
      Logger.error(
        "AgentRunner: rule-based pass crashed for agent #{agent.id}: #{Exception.message(e)}"
      )

      AgentLog.push(agent.id,
        level: :error,
        event: "rule_based_crash",
        message: "Rule-based pass crashed: #{Exception.message(e)}"
      )

      []
  end

  # Fail-closed: only return true for the exact `(agent_type == "trading"
  # AND risk_config.auto_exit_enabled == true)` combination. Anything
  # missing, nil, or otherwise unexpected falls through to `false`.
  defp auto_exit_eligible?(%{agent_type: "trading", risk_config: %{} = rc}) do
    Map.get(rc, "auto_exit_enabled") == true
  end

  defp auto_exit_eligible?(_), do: false

  # Phase 2: called AFTER Repo.with_user closes (no DB connection held).
  # - Push tick_start to the agent log.
  # - Enqueue PositionSyncWorker (Oban INSERT — own fast connection).
  # - Execute rule-based actions (Oban INSERTs — own fast connections).
  # - Call SignalEngine.generate (LLM HTTP — can take several seconds).
  # - Enqueue TradeExecutionWorker if a signal is returned.
  defp run_post_db_phase(agent, context, rule_actions, owner_user_id) do
    AgentLog.push(agent.id,
      event: "tick_start",
      message: "Tick — syncing positions + running cycle"
    )

    # Always sync open positions every tick.
    %{"agent_id" => agent.id, "owner_user_id" => owner_user_id}
    |> PositionSyncWorker.new()
    |> Oban.insert()

    # Execute any rule-based exits collected in Phase 1.
    run_rule_based_exits(agent, rule_actions, owner_user_id)

    # LLM-sourced signal pass. In BYO-LLM mode returns {:hold, "byo_llm_mode"}.
    case SignalEngine.generate(agent, context) do
      {:ok, signal} ->
        Logger.info(
          "AgentRunner: agent #{agent.id} signal=#{signal["action"]} #{signal["market"]} confidence=#{signal["confidence"]}"
        )

        AgentLog.push(agent.id,
          level: :info,
          event: "signal_trade",
          message:
            "Signal: #{signal["action"]} #{signal["market"]} @ confidence #{signal["confidence"]} — enqueueing trade"
        )

        intent =
          signal
          |> Map.put("agent_id", agent.id)
          |> Map.put("owner_user_id", owner_user_id)

        dispatch_trade_intent(agent, "trade_intent", intent)

      {:hold, reason} ->
        Logger.debug("AgentRunner: agent #{agent.id} signal hold — #{reason}")

        AgentLog.push(agent.id,
          level: :debug,
          event: "signal_hold",
          message: "Signal hold — #{reason}"
        )

      {:error, reason} ->
        Logger.error("AgentRunner: signal error for agent #{agent.id}: #{inspect(reason)}")

        AgentLog.push(agent.id,
          level: :error,
          event: "signal_error",
          message: "Signal error: #{inspect(reason)}"
        )
    end
  end

  defp run_rule_based_exits(agent, actions, owner_user_id) do
    if actions == [] do
      AgentLog.push(agent.id,
        level: :debug,
        event: "rule_based_scan",
        message: "Rule-based scan: no exit actions"
      )

      :noop
    else
      Logger.info(
        "AgentRunner: agent #{agent.id} rule-based planned #{length(actions)} exit action(s)"
      )

      AgentLog.push(agent.id,
        level: :info,
        event: "rule_based_exits",
        message: "Rule-based: #{length(actions)} exit action(s) queued"
      )

      Enum.each(actions, fn action ->
        intent = %{
          "agent_id" => agent.id,
          "owner_user_id" => owner_user_id,
          "market" => action.ticker,
          "side" => action.side,
          "action" => "sell",
          "contracts" => action.contracts,
          "fill_price" => to_string(action.fill_price),
          "platform" => to_string(action.platform),
          "reason" => action.reason,
          "source" => "rule_based"
        }

        dispatch_trade_intent(agent, "rule_based_exit", intent)
      end)
    end
  end

  # Passport PR-3 dispatcher gate. Per passport-handoff §1, agents on
  # the per-trade payment rail must NOT have KAH place broker orders
  # on their behalf — KAH writes a `trigger_event` outbox row instead
  # and the user's kpass-side runner executes the trade locally with
  # the brokerage credentials it holds. Every other rail (none /
  # subscription) keeps the direct-broker path unchanged so this PR is
  # zero-regression for existing agents.
  #
  # Exposed as @doc false (not private) so the unit test can exercise
  # both routing branches without spinning up the full GenServer.
  @doc false
  def dispatch_trade_intent(%{payment_rail: "per_trade"} = agent, event_type, intent) do
    case KiteAgentHub.Trading.TriggerEvents.emit(agent, event_type, intent) do
      {:ok, ev} ->
        Logger.info(
          "AgentRunner: agent #{agent.id} per_trade — emitted trigger_event #{ev.id} (#{event_type})"
        )

        AgentLog.push(agent.id,
          event: "trigger_emitted",
          message: "Trigger #{event_type} emitted (#{ev.id}) — awaiting client execution"
        )

        {:ok, ev}

      {:error, :duplicate} ->
        Logger.debug(
          "AgentRunner: agent #{agent.id} per_trade — duplicate trigger #{event_type}, skipping"
        )

        {:error, :duplicate}

      {:error, reason} ->
        Logger.warning(
          "AgentRunner: agent #{agent.id} per_trade trigger emit failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  def dispatch_trade_intent(_agent, _event_type, intent) do
    intent
    |> TradeExecutionWorker.new()
    |> Oban.insert()
  end

  # DB-only slice of the tick context. Runs inside Repo.with_user so
  # the queries inherit RLS scope, then the connection is released
  # before any HTTP work begins.
  defp build_db_context(agent) do
    %{
      market: "ETH-USDC",
      open_positions: Trading.count_open_trades(agent.id),
      recent_trades: Trading.list_open_trades(agent.id) |> Enum.take(5)
    }
  end

  # HTTP-only slice — RPC block + vault balance + PriceOracle/CoinGecko.
  # Each can take seconds (or hit a rate-limit timeout); previously
  # these ran inside Repo.with_user and held a DB connection through
  # the wait, which under load drove the recurring DBConnection
  # checkout-timeout pattern. Mirrors the PR #284 split that did the
  # same for the LLM round-trip.
  defp build_remote_context(agent, %{market: market}) do
    block_number =
      case RPC.block_number() do
        {:ok, n} -> n
        _ -> nil
      end

    vault_balance_wei =
      if agent.vault_address do
        case RPC.vault_balance(agent.vault_address) do
          {:ok, wei} -> wei
          _ -> 0
        end
      else
        0
      end

    oracle_data =
      case PriceOracle.get(market) do
        {:ok, data} -> data
        _ -> %{price: "0.00", trend: "neutral", rsi: 50, change_24h: 0.0}
      end

    %{
      price: oracle_data.price,
      trend: oracle_data.trend,
      rsi: oracle_data.rsi,
      change_24h: oracle_data[:change_24h],
      block_number: block_number,
      vault_balance_wei: vault_balance_wei
    }
  end

  # Jittered schedule. With many active agents all ticking on the same
  # 60s boundary, every connection in the pool gets checked out at the
  # exact same instant — the queueing time for late arrivals exceeds
  # the 15s checkout timeout and the runner crashes. Adding ±25% jitter
  # spreads the load so the pool can serve them in turn.
  defp schedule_tick(interval) do
    jittered = interval + :rand.uniform(div(interval, 2)) - div(interval, 4)
    Process.send_after(self(), :tick, jittered)
  end

  defp via(agent_id) do
    {:via, Registry, {KiteAgentHub.AgentRegistry, agent_id}}
  end
end
