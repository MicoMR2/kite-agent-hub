defmodule KiteAgentHub.Kite.AgentRunner do
  @moduledoc """
  GenServer that drives a single Kite agent through the signal → execute loop.

  Start one per active agent:

      KiteAgentHub.Kite.AgentRunner.start_link(%{agent_id: agent.id, interval_ms: 60_000})

  Every `interval_ms` (default 60s) it:
  1. Reloads the agent — stops itself if agent is no longer active.
  2. Fetches a lightweight market snapshot from Kite chain (block number + vault balance).
  3. Calls SignalEngine.generate/2 with the context.
  4. If {:ok, signal} — enqueues a TradeExecutionWorker job via Oban.
  5. If {:hold, _}   — logs and waits for the next tick.
  6. Enqueues a PositionSyncWorker on every tick to keep settlements current.

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
    # Wrap the with_user transaction in try/rescue so a transient DB
    # pool exhaustion (DBConnection.ConnectionError, RuntimeError from
    # transaction timeout, etc.) does not terminate the GenServer.
    # When the GenServer terminates the supervisor restarts it, which
    # immediately ticks again and hammers the pool further — exactly
    # the cascade we saw in production logs.
    result =
      try do
        Repo.with_user(owner_user_id, fn ->
          agent = Trading.get_agent!(agent_id)

          if agent.status != "active" do
            Logger.info("AgentRunner: agent #{agent_id} is #{agent.status}, stopping runner")
            :stop
          else
            run_cycle(agent, owner_user_id)
            :continue
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

  defp run_cycle(agent, owner_user_id) do
    # Always sync open positions — pass owner_user_id so SettlementWorker can satisfy RLS
    %{"agent_id" => agent.id, "owner_user_id" => owner_user_id}
    |> PositionSyncWorker.new()
    |> Oban.insert()

    # Rule-based exit pass — runs every tick regardless of LLM availability.
    # This is the 24/7 floor: even in BYO-LLM mode (no external signal source),
    # the agent still defends its positions by cutting losers and letting
    # winners run based on live QRB scoring.
    run_rule_based_pass(agent, owner_user_id)

    # LLM-sourced signal pass — only emits trades when SignalEngine is
    # actually wired to an API key or external LLM. In BYO-LLM mode this
    # returns {:hold, "byo_llm_mode"} and is a no-op; the external LLM
    # drives new entries via the /api/v1 endpoints instead.
    context = build_context(agent)

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

  defp run_rule_based_pass(agent, owner_user_id) do
    actions = RuleBasedStrategy.plan_actions(agent)

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
  rescue
    e ->
      Logger.error(
        "AgentRunner: rule-based pass crashed for agent #{agent.id}: #{Exception.message(e)}"
      )
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
