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

  alias KiteAgentHub.{Repo, Trading}
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Kite.RPC

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trade_id" => trade_id} = args, attempt: attempt}) do
    # owner_user_id is passed from TradeExecutionWorker to avoid an owner lookup
    # and to ensure Repo.get! runs inside the correct RLS context from the start.
    owner_user_id =
      args["owner_user_id"] ||
        fallback_owner_user_id(trade_id)

    # `load_phase/3` returns the result of `Repo.with_user/2`, which
    # wraps the inner value in `{:ok, _}`. Match the wrapped shapes
    # — same destructure-trap class as #320 / #322 / the
    # AlpacaSettlementWorker + StuckTradeSweeper fixes in this PR.
    case load_phase(trade_id, owner_user_id, args["tx_hash"]) do
      {:ok, {:already_terminal, status}} ->
        Logger.info("SettlementWorker: trade #{trade_id} already #{status}, skipping")
        :ok

      {:error, reason} ->
        Logger.error(
          "SettlementWorker: with_user failed for trade #{trade_id}: #{inspect(reason)}"
        )

        {:error, "with_user failed"}

      {:ok, {:settle_no_tx, trade}} ->
        Repo.with_user(owner_user_id, fn ->
          Logger.info(
            "SettlementWorker: trade #{trade.id} has no tx_hash, settling as confirmed"
          )

          Trading.settle_trade(trade, Decimal.new(0))
          :ok
        end)

      {:ok, {:check_rpc, trade, tx_hash}} ->
        # Phase 2 — RPC call runs WITHOUT a Repo connection held. The
        # Kite chain JSON-RPC round-trip used to run inside with_user
        # and starved the pool when the node was slow. Now any DB
        # writes that follow re-enter with_user explicitly.
        case RPC.get_transaction_receipt(tx_hash) do
          {:ok, %{"status" => "0x1"}} ->
            Repo.with_user(owner_user_id, fn ->
              Logger.info(
                "SettlementWorker: tx #{tx_hash} confirmed, settling trade #{trade.id}"
              )

              Trading.settle_trade(trade, Decimal.new(0))
              :ok
            end)

          {:ok, %{"status" => "0x0"}} ->
            Repo.with_user(owner_user_id, fn ->
              Logger.warning(
                "SettlementWorker: tx #{tx_hash} reverted, marking trade #{trade.id} failed"
              )

              Trading.update_trade(trade, %{status: "failed"})
              :ok
            end)

          {:ok, nil} ->
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

  # Phase 1: load the trade inside Repo.with_user and decide what to
  # do next. Returns one of:
  #   {:already_terminal, status}   — nothing to do.
  #   {:settle_no_tx, trade}        — off-chain row; settle without RPC.
  #   {:check_rpc, trade, tx_hash}  — caller must do the RPC + Phase 3.
  defp load_phase(trade_id, owner_user_id, args_tx_hash) do
    Repo.with_user(owner_user_id, fn ->
      trade = Repo.get!(TradeRecord, trade_id)

      cond do
        trade.status != "open" ->
          {:already_terminal, trade.status}

        is_nil(args_tx_hash) and is_nil(trade.tx_hash) ->
          {:settle_no_tx, trade}

        true ->
          {:check_rpc, trade, args_tx_hash || trade.tx_hash}
      end
    end)
  end

  # Fallback for jobs that predate the owner_user_id convention.
  # Uses a join on kite_agents + org_memberships — safe raw SELECT by trusted trade_id PK.
  defp fallback_owner_user_id(trade_id) do
    import Ecto.Query

    KiteAgentHub.Orgs.Membership
    |> join(:inner, [m], a in KiteAgentHub.Trading.KiteAgent,
      on: a.organization_id == m.organization_id
    )
    |> join(:inner, [_, a], t in TradeRecord, on: t.kite_agent_id == a.id)
    |> where([_, _, t], t.id == ^trade_id)
    |> where([m], m.role == "owner")
    |> select([m], m.user_id)
    |> limit(1)
    |> Repo.one()
  end

end
