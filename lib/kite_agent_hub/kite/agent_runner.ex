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

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Kite.{RPC, SignalEngine}
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

    Logger.info("AgentRunner: starting for agent #{agent_id}, interval #{interval}ms")

    # Fire the first tick immediately
    send(self(), :tick)

    {:ok, %{agent_id: agent_id, interval_ms: interval}}
  end

  @impl true
  def handle_info(:tick, %{agent_id: agent_id, interval_ms: interval} = state) do
    agent = Trading.get_agent!(agent_id)

    if agent.status != "active" do
      Logger.info("AgentRunner: agent #{agent_id} is #{agent.status}, stopping runner")
      {:stop, :normal, state}
    else
      run_cycle(agent)
      schedule_tick(interval)
      {:noreply, state}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp run_cycle(agent) do
    # Always sync open positions
    %{"agent_id" => agent.id}
    |> PositionSyncWorker.new()
    |> Oban.insert()

    # Build market context from chain
    context = build_context(agent)

    case SignalEngine.generate(agent, context) do
      {:ok, signal} ->
        Logger.info(
          "AgentRunner: agent #{agent.id} signal=#{signal["action"]} #{signal["market"]} confidence=#{signal["confidence"]}"
        )

        signal
        |> Map.put("agent_id", agent.id)
        |> TradeExecutionWorker.new()
        |> Oban.insert()

      {:hold, reason} ->
        Logger.info("AgentRunner: agent #{agent.id} hold — #{reason}")

      {:error, reason} ->
        Logger.error("AgentRunner: signal error for agent #{agent.id}: #{inspect(reason)}")
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

    %{
      market: market,
      price: fetch_market_price(market),
      block_number: block_number,
      vault_balance_wei: vault_balance_wei,
      open_positions: open_count,
      trend: "neutral",
      recent_trades: Trading.list_open_trades(agent.id) |> Enum.take(5)
    }
  end

  defp fetch_market_price(_market) do
    # Placeholder — a real implementation would call a price oracle or DEX
    # For testnet demo purposes, return a static price
    "3250.00"
  end

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end

  defp via(agent_id) do
    {:via, Registry, {KiteAgentHub.AgentRegistry, agent_id}}
  end
end
