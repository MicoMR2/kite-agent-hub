defmodule KiteAgentHub.Workers.PositionSyncWorker do
  @moduledoc """
  Oban worker that syncs open positions for a Kite agent against on-chain state.

  Enqueue via:

      %{"agent_id" => agent.id}
      |> KiteAgentHub.Workers.PositionSyncWorker.new()
      |> Oban.insert()

  Or schedule a recurring sync with `schedule_in: 60`.

  The worker:
  1. Loads the agent and verifies it is active or paused.
  2. Queries all open TradeRecords for the agent.
  3. For each open trade that has a tx_hash, enqueues a SettlementWorker
     (Oban unique constraint prevents duplicate settlement jobs).
  4. Logs the vault balance from Kite chain if a vault_address is present.
  """

  use Oban.Worker,
    queue: :position_sync,
    max_attempts: 5,
    unique: [period: 55, fields: [:args]]

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Kite.RPC
  alias KiteAgentHub.Workers.SettlementWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_id" => agent_id}}) do
    agent = Trading.get_agent!(agent_id)

    if agent.status not in ["active", "paused"] do
      Logger.info("PositionSyncWorker: agent #{agent_id} is #{agent.status}, skipping sync")
      {:cancel, "agent not active or paused"}
    else
      sync_positions(agent)
    end
  end

  defp sync_positions(agent) do
    open_trades = Trading.list_open_trades(agent.id)
    Logger.info("PositionSyncWorker: agent #{agent.id} has #{length(open_trades)} open trade(s)")

    enqueue_pending_settlements(open_trades)
    log_vault_balance(agent)

    :ok
  end

  defp enqueue_pending_settlements(open_trades) do
    Enum.each(open_trades, fn trade ->
      if trade.tx_hash do
        %{"trade_id" => trade.id, "tx_hash" => trade.tx_hash}
        |> SettlementWorker.new()
        |> Oban.insert()
      end
    end)
  end

  defp log_vault_balance(agent) do
    if agent.vault_address do
      case RPC.get_balance(agent.vault_address) do
        {:ok, wei} ->
          eth = wei / :math.pow(10, 18)

          Logger.info(
            "PositionSyncWorker: agent #{agent.id} vault balance #{Float.round(eth, 6)} KITE"
          )

        {:error, reason} ->
          Logger.warning(
            "PositionSyncWorker: balance fetch failed for agent #{agent.id}: #{inspect(reason)}"
          )
      end
    end
  end
end
