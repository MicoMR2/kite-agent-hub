defmodule KiteAgentHub.Workers.KalshiOrderReconciler do
  @moduledoc """
  Read-only reconciler that resolves open Kalshi trade rows against
  upstream Kalshi state.

  Three lookup paths, picked per row in `lookup_strategy/1`:

  * `:by_order_id`   — row has `platform_order_id` (the post-PR-A
    happy path). Calls `GET /portfolio/orders/{id}`. Hard ID match,
    safe to mutate the row from the response.
  * `:by_client_id`  — row has `client_order_id` but no
    `platform_order_id` (the post-PR-B write-ordering recovery path:
    we POSTed but timed out before storing the upstream ID). Calls
    `list_orders(client_order_id: x)`. Hard idempotency match,
    safe to back-fill `platform_order_id` + reconcile.
  * `:legacy_zombie` — row has neither (the 3 stuck KXFEDDECISION
    orders from msg 14251 + any other pre-PR-B writes). LOG ONLY,
    no DB mutation, per CyberSec msg 10651 — speculative ticker+time
    matching against Kalshi is not strong enough to flip status
    without human-in-the-loop sign-off.

  Out of scope for this worker (separate PRs, each with explicit
  Mico approval per CyberSec msg 10649): cancel-order, batch-cancel,
  amend-order, decrease-order.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  alias KiteAgentHub.{Trading, Credentials}
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  @impl Oban.Worker
  def perform(_job) do
    trades = Trading.list_open_kalshi_trades_for_reconcile(older_than_seconds: 60)

    Logger.info("KalshiOrderReconciler sweep: #{length(trades)} candidate row(s)")

    {actioned, logged, skipped, errored} =
      Enum.reduce(trades, {0, 0, 0, 0}, fn trade, {a, l, s, e} ->
        case reconcile_trade(trade) do
          :actioned -> {a + 1, l, s, e}
          :logged -> {a, l + 1, s, e}
          :no_change -> {a, l, s + 1, e}
          :error -> {a, l, s, e + 1}
        end
      end)

    Logger.info(
      "KalshiOrderReconciler done: actioned=#{actioned} logged_only=#{logged} " <>
        "no_change=#{skipped} errors=#{errored}"
    )

    :ok
  end

  @doc false
  def reconcile_trade(%TradeRecord{} = trade) do
    case lookup_strategy(trade) do
      :legacy_zombie ->
        # Read-only ticker-discovery surface for the 3 KXFEDDECISION
        # zombies (and any future NULL-on-both rows). We log what
        # Kalshi sees under that ticker around the trade's insert
        # time, but we do NOT mutate the row — CyberSec msg 10651
        # blocks speculative state changes until human-in-the-loop
        # sign-off lands. Mico/DevOps can read the log line to
        # decide cleanup.
        case discover_legacy(trade) do
          {:ok, orders} ->
            Logger.warning(
              "KalshiOrderReconciler legacy_zombie trade=#{trade.id} " <>
                "agent=#{trade.kite_agent_id} ticker=#{trade.market} " <>
                "upstream_matches=#{length(orders)} — read-only, no DB mutation"
            )

          {:error, reason} ->
            Logger.warning(
              "KalshiOrderReconciler legacy_zombie discovery failed trade=#{trade.id} " <>
                "ticker=#{trade.market} reason=#{inspect(reason)} — read-only, no DB mutation"
            )
        end

        :logged

      strategy ->
        case fetch_kalshi_orders(trade, strategy) do
          {:ok, orders} -> apply_reconcile(trade, strategy, orders)
          {:error, reason} -> log_error(trade, strategy, reason)
        end
    end
  end

  defp discover_legacy(%TradeRecord{} = trade) do
    org_id = trade.kite_agent && trade.kite_agent.organization_id

    with {:ok, org_id} <- ok_or_skip(org_id, :missing_org_id),
         {:ok, {key_id, pem, env}} <- Credentials.fetch_secret_with_env(org_id, :kalshi) do
      # ±10 min window around the trade's inserted_at to bound the
      # Kalshi-side scan. Kalshi `min_ts` / `max_ts` use unix seconds.
      insert_ts = DateTime.to_unix(trade.inserted_at)

      KalshiClient.list_orders(key_id, pem,
        ticker: trade.market,
        min_ts: insert_ts - 600,
        max_ts: insert_ts + 600,
        limit: 20,
        env: env
      )
    end
  end

  @doc false
  def lookup_strategy(%TradeRecord{platform_order_id: id}) when is_binary(id) and id != "",
    do: :by_order_id

  def lookup_strategy(%TradeRecord{client_order_id: id}) when is_binary(id) and id != "",
    do: :by_client_id

  def lookup_strategy(_), do: :legacy_zombie

  @doc false
  # Pure decision: given a trade row + the Kalshi order(s) returned
  # from the lookup, return the reconcile action. Exported under
  # `@doc false` for hermetic test coverage.
  def reconcile_action(%TradeRecord{} = _trade, []), do: {:no_change, :empty_response}

  def reconcile_action(%TradeRecord{} = trade, [order | _]),
    do: reconcile_action_from_status(trade, order)

  defp reconcile_action_from_status(trade, %{status: status, order_id: order_id}) do
    case normalize_status(status) do
      :filled ->
        attrs = %{status: "settled"} |> maybe_put_order_id(trade, order_id)
        {:settle, attrs}

      :cancelled ->
        attrs =
          %{status: "cancelled", reason: "kalshi reconciler: order #{status}"}
          |> maybe_put_order_id(trade, order_id)

        {:cancel, attrs}

      :open ->
        # Row stays open, but back-fill platform_order_id if we just
        # recovered it via client_order_id lookup.
        if is_nil(trade.platform_order_id) and is_binary(order_id) do
          {:backfill, %{platform_order_id: order_id}}
        else
          :no_change
        end

      :unknown ->
        :no_change
    end
  end

  defp reconcile_action_from_status(_trade, _other), do: :no_change

  # Kalshi order lifecycle status strings (per /api-reference/orders):
  # "resting" / "open" → still active on the book
  # "executed" / "filled" → fully filled, ready to settle
  # "canceled" / "cancelled" / "expired" → terminal, no fill
  defp normalize_status(s) when is_binary(s) do
    case String.downcase(s) do
      "executed" -> :filled
      "filled" -> :filled
      "resting" -> :open
      "open" -> :open
      "canceled" -> :cancelled
      "cancelled" -> :cancelled
      "expired" -> :cancelled
      _ -> :unknown
    end
  end

  defp normalize_status(_), do: :unknown

  defp maybe_put_order_id(attrs, %TradeRecord{platform_order_id: nil}, order_id)
       when is_binary(order_id),
       do: Map.put(attrs, :platform_order_id, order_id)

  defp maybe_put_order_id(attrs, _trade, _order_id), do: attrs

  # ── Side effects ─────────────────────────────────────────────────

  defp fetch_kalshi_orders(%TradeRecord{} = trade, strategy) do
    org_id = trade.kite_agent && trade.kite_agent.organization_id

    with {:ok, org_id} <- ok_or_skip(org_id, :missing_org_id),
         {:ok, {key_id, pem, env}} <- Credentials.fetch_secret_with_env(org_id, :kalshi) do
      do_fetch(strategy, trade, key_id, pem, env)
    end
  end

  defp ok_or_skip(nil, reason), do: {:error, reason}
  defp ok_or_skip(value, _reason), do: {:ok, value}

  defp do_fetch(:by_order_id, trade, key_id, pem, env) do
    case KalshiClient.get_order(key_id, pem, trade.platform_order_id, env) do
      {:ok, order} -> {:ok, [order]}
      err -> err
    end
  end

  defp do_fetch(:by_client_id, trade, key_id, pem, env) do
    KalshiClient.list_orders(key_id, pem,
      client_order_id: trade.client_order_id,
      limit: 5,
      env: env
    )
  end

  defp apply_reconcile(trade, strategy, orders) do
    case reconcile_action(trade, orders) do
      {:settle, attrs} ->
        log_action(trade, strategy, :settle, orders)
        Trading.update_trade(trade, attrs)
        :actioned

      {:cancel, attrs} ->
        log_action(trade, strategy, :cancel, orders)
        Trading.update_trade(trade, attrs)
        :actioned

      {:backfill, attrs} ->
        log_action(trade, strategy, :backfill, orders)
        Trading.update_trade(trade, attrs)
        :actioned

      :no_change ->
        :no_change

      {:no_change, _why} ->
        :no_change
    end
  end

  defp log_action(trade, strategy, action, orders) do
    order_count = length(orders)

    Logger.info(
      "KalshiOrderReconciler #{action} trade=#{trade.id} agent=#{trade.kite_agent_id} " <>
        "strategy=#{strategy} ticker=#{trade.market} upstream_orders=#{order_count}"
    )
  end

  defp log_error(trade, strategy, reason) do
    # PR-D₄ sanitization (CyberSec 10671①②): only the status code
    # from `reason` reaches the log; the full Kalshi response body
    # — which may carry order details or Kalshi internal codes —
    # stays out of the surface.
    Logger.warning(
      "KalshiOrderReconciler error trade=#{trade.id} strategy=#{strategy} " <>
        "status=#{KalshiClient.sanitize_for_log(reason)}"
    )

    :error
  end
end
