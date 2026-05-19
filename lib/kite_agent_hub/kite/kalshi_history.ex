defmodule KiteAgentHub.Kite.KalshiHistory do
  @moduledoc """
  Persistence layer for Kalshi historical candlesticks. Single helper
  `upsert_candles/1` swallows the dedup contract from the unique
  index on `(ticker, ts, period_minutes)` so callers (ingestion
  workers, manual IEx backfills) don't have to think about it.

  Range queries for backtest replay belong here too — `list_candles/3`
  is the entry point. Phase 2 KalshiEdgeScorer reads through this
  module, never the schema or raw Repo.
  """

  import Ecto.Query

  alias KiteAgentHub.Kite.KalshiHistoricalCandlestick
  alias KiteAgentHub.Repo

  @doc """
  Bulk-upsert parsed candles. Rows with the same (ticker, ts, period)
  are updated; new rows are inserted. Returns `{count, nil}` from
  `Repo.insert_all`. Rejects entries missing `:ts` (Kalshi sometimes
  ships a placeholder row with null timestamp on edge cases — drop
  it before hitting the DB).
  """
  def upsert_candles(rows) when is_list(rows) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    valid =
      rows
      |> Enum.filter(&valid_row?/1)
      |> Enum.map(&Map.merge(&1, %{inserted_at: now, updated_at: now}))

    case valid do
      [] ->
        {0, nil}

      _ ->
        Repo.insert_all(
          KalshiHistoricalCandlestick,
          valid,
          on_conflict: {:replace, [:yes_open_cents, :yes_close_cents, :yes_high_cents, :yes_low_cents, :volume, :open_interest, :updated_at]},
          conflict_target: [:ticker, :ts, :period_minutes]
        )
    end
  end

  @doc false
  def valid_row?(%{ticker: t, ts: ts, period_minutes: p})
      when is_binary(t) and not is_nil(ts) and is_integer(p) and p > 0,
      do: true

  def valid_row?(_), do: false

  @doc """
  Pull historical candles for a single ticker in a time window. Used
  by backtests + Phase 2 scoring features that need recent price
  trajectory. Caller picks the period_minutes — no implicit default
  because mixing periods in a single trajectory is a bug surface.
  """
  def list_candles(ticker, period_minutes, opts \\ []) when is_binary(ticker) do
    start_ts = Keyword.get(opts, :start_ts)
    end_ts = Keyword.get(opts, :end_ts)
    limit = Keyword.get(opts, :limit, 1_000)

    KalshiHistoricalCandlestick
    |> where([c], c.ticker == ^ticker and c.period_minutes == ^period_minutes)
    |> maybe_where_ts_gte(start_ts)
    |> maybe_where_ts_lte(end_ts)
    |> order_by(asc: :ts)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_where_ts_gte(q, nil), do: q
  defp maybe_where_ts_gte(q, %DateTime{} = ts), do: where(q, [c], c.ts >= ^ts)

  defp maybe_where_ts_lte(q, nil), do: q
  defp maybe_where_ts_lte(q, %DateTime{} = ts), do: where(q, [c], c.ts <= ^ts)
end
