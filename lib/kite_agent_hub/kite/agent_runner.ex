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

  The runner is supervised by AgentRunnerSupervisor.
  """

  use GenServer, restart: :transient

  require Logger

  alias KiteAgentHub.{Trading, Repo}
  alias KiteAgentHub.Kite.{RPC, SignalEngine, PriceOracle, RuleBasedStrategy}
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
            # Rule-based exit pass needs the RLS context for edge-score queries.
            rule_actions = collect_rule_based_actions(agent)
            # Context build reads trade counts / open positions — also needs RLS.
            context = build_context(agent)
            {:run, agent, context, rule_actions}
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

        {:ok, {:run, agent, context, rule_actions}} ->
          # DB connection is released. Now do the slow I/O.
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

  # Collect rule-based exit actions while still inside Repo.with_user.
  # Returns a (possibly empty) list of action maps. Crashes are caught so
  # a buggy edge-scorer doesn't take down the whole runner.
  defp collect_rule_based_actions(agent) do
    RuleBasedStrategy.plan_actions(agent)
  rescue
    e ->
      Logger.error(
        "AgentRunner: rule-based pass crashed for agent #{agent.id}: #{Exception.message(e)}"
      )

      []
  end

  # Phase 2: called AFTER Repo.with_user closes (no DB connection held).
  # - Enqueue PositionSyncWorker (Oban INSERT — own fast connection).
  # - Execute rule-based actions (Oban INSERTs — own fast connections).
  # - Call SignalEngine.generate (LLM HTTP — can take several seconds).
  # - Enqueue TradeExecutionWorker if a signal is returned.
  defp run_post_db_phase(agent, context, rule_actions, owner_user_id) do
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

        signal
        |> Map.put("agent_id", agent.id)
        |> Map.put("owner_user_id", owner_user_id)
        |> TradeExecutionWorker.new()
        |> Oban.insert()

      {:hold, reason} ->
        Logger.debug("AgentRunner: agent #{agent.id} signal hold — #{reason}")

      {:error, reason} ->
        Logger.error("AgentRunner: signal error for agent #{agent.id}: #{inspect(reason)}")
    end
  end

  defp run_rule_based_exits(agent, actions, owner_user_id) do
    if actions == [] do
      :noop
    else
      Logger.info(
        "AgentRunner: agent #{agent.id} rule-based planned #{length(actions)} exit action(s)"
      )

      Enum.each(actions, fn action ->
        %{
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
        |> TradeExecutionWorker.new()
        |> Oban.insert()
      end)
    end
  end

  defp build_context(agent) do
    market = "ETH-USDC"

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

    open_count = Trading.count_open_trades(agent.id)

    oracle_data =
      case PriceOracle.get(market) do
        {:ok, data} -> data
        _ -> %{price: "0.00", trend: "neutral", rsi: 50, change_24h: 0.0}
      end

    %{
      market: market,
      price: oracle_data.price,
      trend: oracle_data.trend,
      rsi: oracle_data.rsi,
      change_24h: oracle_data[:change_24h],
      block_number: block_number,
      vault_balance_wei: vault_balance_wei,
      open_positions: open_count,
      recent_trades: Trading.list_open_trades(agent.id) |> Enum.take(5)
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
