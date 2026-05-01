defmodule KiteAgentHub.Trading.BrokerStats do
  @moduledoc """
  Pulls realized P&L and win/loss stats directly from Alpaca and Kalshi
  rather than computing from local TradeRecord rows. The DB-based
  `Trading.agent_pnl_stats/1` only counted trades that flowed through
  the platform-as-broker path, so any pre-PR-#85 trade or any trade
  placed outside KAH was invisible. The brokers themselves are the
  source of truth for fills and settlements — this module just asks
  them and normalizes the answer to the same map shape DashboardLive
  already renders.

  Returned shape (matches the existing `agent_pnl_stats/1` contract so
  the dashboard template needs zero changes):

      %{
        total_pnl: Decimal.t(),
        win_count: integer(),
        loss_count: integer(),
        trade_count: integer(),
        open_count: integer()
      }

  All stats are scoped per ORGANIZATION, not per agent — Alpaca and
  Kalshi both track orders by account, not by KAH agent, so multiple
  agents under the same org share the same broker-side history. This
  is the correct grain even though the dashboard currently keys
  pnl_stats by selected agent — the numbers will simply match across
  agents in the same org.
  """

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient}

  @empty %{
    total_pnl: Decimal.new(0),
    win_count: 0,
    loss_count: 0,
    trade_count: 0,
    open_count: 0
  }

  @empty_account %{
    equity: nil,
    buying_power: nil,
    regt_buying_power: nil,
    daytrading_buying_power: nil,
    non_marginable_buying_power: nil,
    multiplier: nil,
    shorting_enabled: nil,
    status: nil
  }

  @doc """
  Fetch live broker stats for an organization. Combines Alpaca FIFO
  realized P&L from closed orders + Kalshi settlement revenue.
  Returns the empty map shape if neither broker is configured —
  never raises.
  """
  def live_stats(nil), do: @empty

  def live_stats(org_id) do
    alpaca = alpaca_stats(org_id)
    kalshi = kalshi_stats(org_id)
    merge(alpaca, kalshi)
  end

  @doc """
  Fetch the Alpaca account-level summary used by the dashboard's
  margin-headroom card. Returns the empty shape (all nils) when no
  Alpaca credentials are wired so the template can simply check
  `equity != nil` to decide whether to render. Never raises.
  """
  def account_info(nil), do: @empty_account

  def account_info(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.account(key_id, secret, env) do
          {:ok, account} -> Map.merge(@empty_account, account)
          _ -> @empty_account
        end

      _ ->
        @empty_account
    end
  end

  # ── Alpaca ──────────────────────────────────────────────────────────────────

  defp alpaca_stats(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        closed_orders =
          case AlpacaClient.orders(key_id, secret, 200, env) do
            {:ok, list} -> list
            _ -> []
          end

        open_count =
          case AlpacaClient.positions(key_id, secret, env) do
            {:ok, positions} -> length(positions)
            _ -> 0
          end

        {total, wins, losses, trade_count} = fifo_realized_pnl(closed_orders)

        %{
          total_pnl: total,
          win_count: wins,
          loss_count: losses,
          trade_count: trade_count,
          open_count: open_count
        }

      _ ->
        @empty
    end
  end

  # FIFO buy/sell pairing per symbol. Walks the closed orders list in
  # chronological order, builds a per-symbol queue of buy lots, and
  # consumes lots when a sell comes through. Each closed lot's realized
  # P&L = (sell_price - buy_price) * matched_qty. Wins are positive,
  # losses negative, total is the algebraic sum. trade_count counts
  # closed lots, NOT opens — matches Alpaca's "filled order pair" notion.
  defp fifo_realized_pnl(closed_orders) do
    sorted =
      closed_orders
      |> Enum.filter(&(&1.filled_qty && &1.filled_qty > 0 && &1.filled_avg_price))
      |> Enum.sort_by(& &1.submitted_at)

    {_remaining_lots, total, wins, losses, count} =
      Enum.reduce(sorted, {%{}, 0.0, 0, 0, 0}, fn order, {lots, total, wins, losses, count} ->
        case order.side do
          "buy" ->
            queue = Map.get(lots, order.symbol, [])
            new_queue = queue ++ [{order.filled_qty, order.filled_avg_price}]
            {Map.put(lots, order.symbol, new_queue), total, wins, losses, count}

          "sell" ->
            queue = Map.get(lots, order.symbol, [])
            {pnl, leftover_queue} = consume_lots(queue, order.filled_qty, order.filled_avg_price, 0.0)

            new_total = total + pnl
            new_wins = if pnl > 0, do: wins + 1, else: wins
            new_losses = if pnl < 0, do: losses + 1, else: losses

            {Map.put(lots, order.symbol, leftover_queue), new_total, new_wins, new_losses, count + 1}

          _ ->
            {lots, total, wins, losses, count}
        end
      end)

    {Decimal.from_float(total * 1.0), wins, losses, count}
  end

  defp consume_lots(queue, 0, _sell_price, acc), do: {acc, queue}
  defp consume_lots([], _qty_left, _sell_price, acc), do: {acc, []}

  defp consume_lots([{lot_qty, lot_price} | rest], qty_left, sell_price, acc) when lot_qty <= qty_left do
    pnl = (sell_price - lot_price) * lot_qty
    consume_lots(rest, qty_left - lot_qty, sell_price, acc + pnl)
  end

  defp consume_lots([{lot_qty, lot_price} | rest], qty_left, sell_price, acc) do
    pnl = (sell_price - lot_price) * qty_left
    {acc + pnl, [{lot_qty - qty_left, lot_price} | rest]}
  end

  # ── Kalshi ──────────────────────────────────────────────────────────────────

  defp kalshi_stats(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :kalshi) do
      {:ok, {key_id, pem, env}} ->
        settlements =
          case KalshiClient.settlements(key_id, pem, 200, env) do
            {:ok, list} -> list
            _ -> []
          end

        positions =
          case KalshiClient.positions(key_id, pem, env) do
            {:ok, list} -> list
            _ -> []
          end

        total = Enum.reduce(settlements, 0.0, fn s, acc -> acc + (s.revenue || 0.0) end)
        wins = Enum.count(settlements, fn s -> (s.revenue || 0.0) > 0 end)
        losses = Enum.count(settlements, fn s -> (s.revenue || 0.0) < 0 end)
        trade_count = length(settlements)
        open_count = Enum.count(positions, fn p -> (p.contracts || 0) > 0 end)

        %{
          total_pnl: Decimal.from_float(total * 1.0),
          win_count: wins,
          loss_count: losses,
          trade_count: trade_count,
          open_count: open_count
        }

      _ ->
        @empty
    end
  end

  # ── Merge ───────────────────────────────────────────────────────────────────

  defp merge(a, b) do
    %{
      total_pnl: Decimal.add(a.total_pnl, b.total_pnl),
      win_count: a.win_count + b.win_count,
      loss_count: a.loss_count + b.loss_count,
      trade_count: a.trade_count + b.trade_count,
      open_count: a.open_count + b.open_count
    }
  end
end
