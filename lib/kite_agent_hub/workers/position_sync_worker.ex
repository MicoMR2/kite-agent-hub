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

    # `Repo.with_user/2` wraps `transaction/1`, so its return is
    # `{:ok, value}` on success — destructure the outer `:ok` before
    # binding the inner shape. Same destructure-trap class as #320 /
    # #322 / the AlpacaSettlementWorker + StuckTradeSweeper +
    # SettlementWorker fixes in this PR. Pre-fix the case matched
    # `{:cancel, _}` and `{:ok, agent}` directly — `{:cancel, _}`
    # never matched, and `{:ok, agent}` accidentally bound `agent`
    # to the inner `{:cancel, ...}` or `{:ok, agent_struct}` tuple,
    # then `log_vault_balance/1` crashed silently on `agent.vault_address`.
    case Repo.with_user(owner_user_id, fn ->
           agent = Trading.get_agent!(agent_id)

           if agent.status not in ["active", "paused"] do
             Logger.info(
               "PositionSyncWorker: agent #{agent_id} is #{agent.status}, skipping sync"
             )

             {:cancel, "agent not active or paused"}
           else
             open_trades = Trading.list_open_trades(agent.id)

             Logger.info(
               "PositionSyncWorker: agent #{agent.id} has #{length(open_trades)} open trade(s)"
             )

             enqueue_pending_settlements(open_trades, owner_user_id)
             {:ok, agent}
           end
         end) do
      {:ok, {:cancel, _reason} = result} ->
        result

      {:ok, {:ok, agent}} ->
        # Phase 2 — Repo connection released. `log_vault_balance/1`
        # makes a JSON-RPC HTTP call to the Kite chain; previously
        # it ran inside the with_user block and held a DB
        # connection through the round-trip, contributing to the
        # pool checkout-timeout pattern.
        log_vault_balance(agent)
        :ok

      {:error, reason} ->
        Logger.error(
          "PositionSyncWorker: with_user failed for agent #{agent_id}: #{inspect(reason)}"
        )

        {:error, "with_user failed"}
    end
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
