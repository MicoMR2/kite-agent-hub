defmodule KiteAgentHub.Workers.PositionSyncWorker do
  @moduledoc """
  Oban worker that syncs open positions for a Kite agent against on-chain state.

  Enqueue via:

      %{"agent_id" => agent.id, "owner_user_id" => owner_user_id}
      |> KiteAgentHub.Workers.PositionSyncWorker.new()
      |> Oban.insert()

  owner_user_id is required for RLS — all DB reads run inside Repo.with_user/2.

  The worker:
  1. Loads the agent (inside user context) and verifies it is active or paused.
  2. Queries all open TradeRecords for the agent.
  3. For each open trade that has a tx_hash, enqueues a SettlementWorker
     with owner_user_id so SettlementWorker can satisfy RLS.
  4. Logs the vault balance from Kite chain if a vault_address is present.
  """

  use Oban.Worker,
    queue: :position_sync,
    max_attempts: 5,
    unique: [period: 55, fields: [:args]]

  require Logger

  alias KiteAgentHub.{Trading, Repo}
  alias KiteAgentHub.Kite.RPC
  alias KiteAgentHub.Workers.SettlementWorker

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_id" => agent_id} = args}) do
    owner_user_id = args["owner_user_id"] || resolve_owner(agent_id)

    Repo.with_user(owner_user_id, fn ->
      agent = Trading.get_agent!(agent_id)

      if agent.status not in ["active", "paused"] do
        Logger.info("PositionSyncWorker: agent #{agent_id} is #{agent.status}, skipping sync")
        {:cancel, "agent not active or paused"}
      else
        sync_positions(agent, owner_user_id)
      end
    end)
  end

  defp sync_positions(agent, owner_user_id) do
    open_trades = Trading.list_open_trades(agent.id)
    Logger.info("PositionSyncWorker: agent #{agent.id} has #{length(open_trades)} open trade(s)")

    enqueue_pending_settlements(open_trades, owner_user_id)
    log_vault_balance(agent)

    :ok
  end

  defp enqueue_pending_settlements(open_trades, owner_user_id) do
    Enum.each(open_trades, fn trade ->
      if trade.tx_hash do
        %{"trade_id" => trade.id, "tx_hash" => trade.tx_hash, "owner_user_id" => owner_user_id}
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

  # Fallback owner resolution using SECURITY DEFINER SQL — bypasses RLS safely.
  # agent_id comes from trusted Oban job args (never user input).
  defp resolve_owner(agent_id) do
    Repo.owner_user_id_for_agent(agent_id)
  end
end
