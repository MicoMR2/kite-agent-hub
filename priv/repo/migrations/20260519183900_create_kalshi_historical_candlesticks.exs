defmodule KiteAgentHub.Repo.Migrations.CreateKalshiHistoricalCandlesticks do
  use Ecto.Migration

  # Per-candle Kalshi market history for backtesting + the Phase 2
  # KalshiEdgeScorer (Phorari 10745). Period is stored in minutes
  # (1, 5, 60, 1440) so candles of different durations live in the
  # same table — querying for a specific period filters by integer.
  # Yes-side prices in cents (Kalshi's native unit, 0-100).
  def change do
    create table(:kalshi_historical_candlesticks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticker, :string, null: false
      add :ts, :utc_datetime_usec, null: false
      add :period_minutes, :integer, null: false
      add :yes_open_cents, :integer
      add :yes_close_cents, :integer
      add :yes_high_cents, :integer
      add :yes_low_cents, :integer
      add :volume, :integer
      add :open_interest, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:kalshi_historical_candlesticks, [:ticker, :ts, :period_minutes],
             name: :kalshi_historical_candlesticks_ticker_ts_period_index
           )

    # Range queries on a single ticker over time are the dominant
    # backtest access pattern — backstop the unique index with a
    # narrower one on (ticker, ts) so the planner doesn't need to
    # filter on period inside the unique scan.
    create index(:kalshi_historical_candlesticks, [:ticker, :ts])
  end
end
