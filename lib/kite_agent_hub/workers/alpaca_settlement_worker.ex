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
  # IMPORTANT: only `filled_avg_price` is a price; `qty` is shares and
  # must NEVER be used as a price fallback (Phorari PR #87 review).
  # The downstream `if fill_price` guard already skips nil correctly.
  defp handle_status(trade, "filled", order) do
    fill_price = order.filled_avg_price
    filled_qty = order.filled_qty || order.qty

    Logger.info(
      "AlpacaSettlementWorker: trade #{trade.id} FILLED — #{inspect(filled_qty)} @ #{inspect(fill_price)}"
    )

    update_attrs = %{}

    update_attrs =
      if fill_price,
        do: Map.put(update_attrs, :fill_price, Decimal.from_float(fill_price * 1.0)),
        else: update_attrs

    # PR #100: only overwrite :contracts when the truncated fill is at
    # least 1. Crypto fills come back as fractional (e.g. 0.997499992
    # BTC after Alpaca's ~0.25% taker fee), and trunc → 0 violates the
    # `contracts > 0` schema validation, leaving the trade stuck open
    # forever. The original requested contracts value is the right
    # fallback — fill_price still gets updated correctly above, so
    # P&L math stays accurate.
    update_attrs =
      if filled_qty && trunc(filled_qty) > 0,
        do: Map.put(update_attrs, :contracts, trunc(filled_qty)),
        else: update_attrs

    # Two-step update: first persist the actual fill numbers, then
    # flip the row to settled. We must thread the updated struct into
    # settle_trade — calling settle_trade(trade, _) on the original
    # stale struct would mark the row settled but lose the fill_price
    # write we just made (Phorari PR #87 review bug 2).
    case maybe_update_fill(trade, update_attrs) do
      {:ok, updated_trade} ->
        case Trading.settle_trade(updated_trade, Decimal.new(0)) do
          {:ok, settled_trade} ->
            enqueue_attestation(settled_trade)
            {:ok, settled_trade}

          other ->
            other
        end

      {:error, reason} ->
        Logger.error(
          "AlpacaSettlementWorker: trade #{trade.id} fill update failed — leaving open: #{inspect(reason)}"
        )
    end
  end

  # PR #101: enqueue a Kite chain attestation job for every successfully
  # settled trade. The KiteAttestationWorker is idempotent (skips on
  # existing attestation_tx_hash and uses a deterministic nonce derived
  # from the trade UUID), so re-enqueueing is safe.
  defp enqueue_attestation(%{id: trade_id}) do
    %{trade_id: trade_id}
    |> KiteAgentHub.Workers.KiteAttestationWorker.new()
    |> Oban.insert()
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

  # done_for_day and replaced are non-terminal but rare — log a warning
  # so we know they happened without flooding the logs on the common
  # path. Still left open and re-polled next tick.
  defp handle_status(trade, status, _order) when status in ["done_for_day", "replaced"] do
    Logger.warning(
      "AlpacaSettlementWorker: trade #{trade.id} unusual status #{status} — leaving open"
    )
  end

  # Anything else (new, accepted, partially_filled, pending_*) — leave
  # the trade open and try again next minute. Log at info so we can
  # see exactly what Alpaca is reporting in prod logs (the catch-all
  # used to be Logger.debug which is silenced in prod and made it
  # impossible to tell whether a stuck trade was waiting on the broker
  # or hitting a state we forgot to handle).
  defp handle_status(trade, status, _order) do
    Logger.info(
      "AlpacaSettlementWorker: trade #{trade.id} still #{status} — will re-poll next tick"
    )
  end

  # No fill data came back — return the original struct so the caller
  # can still settle the row. Status will be flipped to settled but
  # fill_price stays at whatever TradeExecutionWorker initially wrote.
  defp maybe_update_fill(trade, attrs) when map_size(attrs) == 0, do: {:ok, trade}

  defp maybe_update_fill(trade, attrs) do
    trade
    |> TradeRecord.changeset(attrs)
    |> Repo.update()
  end
end
