defmodule KiteAgentHub.Kite.KalshiHistoricalCandlestick do
  @moduledoc """
  Persisted Kalshi candlestick — one row per (ticker, ts, period_minutes).
  Insert-only via upsert; price + volume columns stay null when Kalshi
  returns a gap (no trades in the bucket).

  `period_minutes` mirrors Kalshi's `period_interval` query (1, 5, 60,
  1440). Storing as integer keeps multi-period rows for the same
  ticker queryable without an enum migration when Kalshi adds new
  periods.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "kalshi_historical_candlesticks" do
    field :ticker, :string
    field :ts, :utc_datetime_usec
    field :period_minutes, :integer
    field :yes_open_cents, :integer
    field :yes_close_cents, :integer
    field :yes_high_cents, :integer
    field :yes_low_cents, :integer
    field :volume, :integer
    field :open_interest, :integer

    timestamps(type: :utc_datetime)
  end

  @required ~w(ticker ts period_minutes)a
  @optional ~w(yes_open_cents yes_close_cents yes_high_cents yes_low_cents volume open_interest)a

  def changeset(candle, attrs) do
    candle
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:period_minutes, greater_than: 0)
  end
end
