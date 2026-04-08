defmodule KiteAgentHub.Workers.AlpacaSettlementWorker do
  @moduledoc """
  Cron-driven Oban worker that closes the Alpaca side of the trade
  lifecycle. `TradeExecutionWorker` opens a TradeRecord with status
  `"open"` the moment the order is submitted to Alpaca, but the
  actual fill (price + qty) only lands later. This worker polls
  Alpaca every minute, finds those open Alpaca trades, asks
  `AlpacaClient.get_order/4` for the current fill state, and:

    - filled        → settle the trade with the actual filled_avg_price
    - canceled      → mark cancelled
    - expired       → mark cancelled
    - rejected      → mark failed
    - everything    → leave open and try again next tick
      else (new,
      accepted,
      partially_filled,
      pending_*)

  Architecture stays platform-as-broker: the agent never holds raw
  Alpaca credentials. The worker uses `Repo.active_agents_with_owners/0`
  to enumerate active agents (SECURITY DEFINER, bypasses RLS), then
  re-establishes the per-agent RLS scope via `Repo.with_user/2` before
  reading the agent's open trades and decrypted Alpaca credential.
  """

  use Oban.Worker,
    queue: :settlement,
    max_attempts: 3,
    unique: [period: 30, fields: [:worker]]

  require Logger

  alias KiteAgentHub.{Credentials, Repo, Trading}
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  @impl Oban.Worker
  def perform(_job) do
    agents = Repo.active_agents_with_owners()
    Logger.info("AlpacaSettlementWorker: scanning #{length(agents)} active agent(s)")

    Enum.each(agents, fn {agent_id, owner_user_id} ->
      Repo.with_user(owner_user_id, fn -> settle_for_agent(agent_id) end)
    end)

    :ok
  end

  defp settle_for_agent(agent_id) do
    open_trades = Trading.list_open_alpaca_trades(agent_id)

    case open_trades do
      [] ->
        :ok

      trades ->
        agent = Trading.get_agent!(agent_id)

        case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
          {:ok, {key_id, secret, env}} ->
            Logger.info(
              "AlpacaSettlementWorker: agent #{agent_id} polling #{length(trades)} open trade(s) (env=#{env})"
            )

            Enum.each(trades, &poll_and_update(&1, key_id, secret, env))

          {:error, reason} ->
            Logger.warning(
              "AlpacaSettlementWorker: skipping agent #{agent_id} — credentials unavailable: #{inspect(reason)}"
            )
        end
    end
  end

  defp poll_and_update(trade, key_id, secret, env) do
    case AlpacaClient.get_order(key_id, secret, trade.platform_order_id, env) do
      {:ok, %{status: status} = order} ->
        handle_status(trade, status, order)

      {:error, reason} ->
        Logger.warning(
          "AlpacaSettlementWorker: trade #{trade.id} order #{trade.platform_order_id} fetch failed: #{inspect(reason)}"
        )
    end
  end

  # Filled — settle with the actual fill price. Update fill_price first
  # via the general changeset, then run settle_changeset to flip status.
  defp handle_status(trade, "filled", order) do
    fill_price = order.filled_avg_price || order.qty
    filled_qty = order.filled_qty || order.qty

    Logger.info(
      "AlpacaSettlementWorker: trade #{trade.id} FILLED — #{filled_qty} @ #{fill_price}"
    )

    update_attrs = %{}
    update_attrs = if fill_price, do: Map.put(update_attrs, :fill_price, Decimal.from_float(fill_price * 1.0)), else: update_attrs
    update_attrs = if filled_qty, do: Map.put(update_attrs, :contracts, trunc(filled_qty)), else: update_attrs

    if map_size(update_attrs) > 0 do
      trade
      |> TradeRecord.changeset(update_attrs)
      |> Repo.update()
    end

    Trading.settle_trade(trade, Decimal.new(0))
  end

  # Terminal failure states — flip to cancelled/failed and stop polling.
  defp handle_status(trade, status, _order) when status in ["canceled", "expired"] do
    Logger.info("AlpacaSettlementWorker: trade #{trade.id} #{status} — marking cancelled")

    trade
    |> TradeRecord.changeset(%{status: "cancelled"})
    |> Repo.update()
  end

  defp handle_status(trade, "rejected", _order) do
    Logger.warning("AlpacaSettlementWorker: trade #{trade.id} REJECTED — marking failed")

    trade
    |> TradeRecord.changeset(%{status: "failed"})
    |> Repo.update()
  end

  # Anything else (new, accepted, partially_filled, pending_*) — leave
  # the trade open and try again next minute.
  defp handle_status(trade, status, _order) do
    Logger.debug(
      "AlpacaSettlementWorker: trade #{trade.id} still #{status} — will re-poll next tick"
    )
  end
end
