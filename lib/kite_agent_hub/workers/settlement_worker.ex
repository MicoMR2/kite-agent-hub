defmodule KiteAgentHub.Workers.SettlementWorker do
  @moduledoc """
  Oban worker that checks open trades against the chain and settles them.

  Enqueue via:

      %{"trade_id" => trade.id, "tx_hash" => "0x..."}
      |> KiteAgentHub.Workers.SettlementWorker.new()
      |> Oban.insert()

  Or use `schedule_in: 30` to check after 30 seconds.

  The worker:
  1. Loads the TradeRecord.
  2. Calls RPC.get_transaction_receipt to check if the tx landed.
  3. On success, calls Trading.settle_trade/2 with a realized PnL placeholder.
  4. On pending, re-enqueues itself after a backoff.
  5. On failure, marks the trade as "failed".
  """

  use Oban.Worker,
    queue: :settlement,
    max_attempts: 10,
    unique: [period: 60, fields: [:args]]

  require Logger

  alias KiteAgentHub.{Repo, Trading, Orgs}
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Kite.RPC

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trade_id" => trade_id} = args, attempt: attempt}) do
    # Load trade outside RLS context (by primary key) — safe read before we know the owner
    trade = Repo.get!(TradeRecord, trade_id)

    if trade.status != "open" do
      Logger.info("SettlementWorker: trade #{trade_id} already #{trade.status}, skipping")
      :ok
    else
      tx_hash = args["tx_hash"] || trade.tx_hash
      agent = Trading.get_agent!(trade.kite_agent_id)
      owner_user_id = Orgs.get_org_owner_user_id(agent.organization_id)
      Repo.with_user(owner_user_id, fn -> check_and_settle(trade, tx_hash, attempt) end)
    end
  end

  defp check_and_settle(trade, nil, _attempt) do
    # No tx hash — settle as confirmed (off-chain trade record)
    Logger.info("SettlementWorker: trade #{trade.id} has no tx_hash, settling as confirmed")
    Trading.settle_trade(trade, Decimal.new(0))
    :ok
  end

  defp check_and_settle(trade, tx_hash, attempt) do
    case RPC.get_transaction_receipt(tx_hash) do
      {:ok, %{"status" => "0x1"}} ->
        # Transaction succeeded on-chain
        Logger.info("SettlementWorker: tx #{tx_hash} confirmed, settling trade #{trade.id}")
        Trading.settle_trade(trade, Decimal.new(0))
        :ok

      {:ok, %{"status" => "0x0"}} ->
        # Transaction reverted
        Logger.warning(
          "SettlementWorker: tx #{tx_hash} reverted, marking trade #{trade.id} failed"
        )

        trade
        |> TradeRecord.changeset(%{status: "failed"})
        |> Repo.update()

        :ok

      {:ok, nil} ->
        # Not mined yet — snooze with exponential backoff
        backoff = min(30 * attempt, 300)

        Logger.info(
          "SettlementWorker: tx #{tx_hash} pending (attempt #{attempt}), retry in #{backoff}s"
        )

        {:snooze, backoff}

      {:error, reason} ->
        Logger.error("SettlementWorker: RPC error for #{tx_hash}: #{inspect(reason)}")
        {:error, "rpc error"}
    end
  end
end
