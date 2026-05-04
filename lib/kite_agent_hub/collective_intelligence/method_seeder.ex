defmodule KiteAgentHub.CollectiveIntelligence.MethodSeeder do
  @moduledoc """
  Method-specific synthetic backtest generator.

  Unlike `Seeder` which generates generic bar-based insights for any
  market, `MethodSeeder` gates each backtest run on method-specific
  entry conditions so the corpus only contains insights that would
  have applied in a realistic deployment.

  ## M-007 Carry Trade (OANDA)

  The carry trade (long high-yield, short low-yield currency) only has
  positive expected value in low-volatility environments. During
  risk-off episodes (COVID, GFC, sudden Fed pivots) the carry unwind
  is violent and fast — any historical bar that looks like a winning
  carry entry actually happened in a risk regime where the strategy
  should be off. Gating on realised vol prevents the corpus from
  being flooded with survivorship-biased carry wins.

  Condition check: `m007_conditions_met?/2`
    * `bars`       — list of OANDA mid-close bars for the carry pair
    * `max_ann_vol` — annualised vol ceiling (default 10.0 %)

  Insight generation: `insights_for_m007/2`
    * Uses `Seeder.insights_from_bars/2` with forex-specific opts.
    * Returns `[]` when conditions are NOT met — caller inserts nothing.
  """

  alias KiteAgentHub.CollectiveIntelligence.Seeder

  @seed_version "method-seed-m007-v1-2026-05"

  @doc """
  Check whether M-007 (carry trade) conditions are met for a given bar
  series. Returns `true` when:

  1. There are at least `min_bars` bars (default 20) — need enough history
     to compute a meaningful volatility estimate.
  2. Annualised realised volatility of daily log returns is < `max_ann_vol`
     percent (default 10.0) — low-vol regime is required for carry.

  `bars` may be OANDA candle maps (string keys, "mid.c" extracted) or the
  atom-key shape `%{c: price}` that `Seeder` already uses.
  """
  @spec m007_conditions_met?(list(), keyword()) :: boolean()
  def m007_conditions_met?(bars, opts \\ []) do
    min_bars = Keyword.get(opts, :min_bars, 20)
    max_ann_vol = Keyword.get(opts, :max_ann_vol, 10.0)

    closes = extract_closes(bars)

    if length(closes) < min_bars do
      false
    else
      ann_vol = realised_vol_pct(closes)
      ann_vol < max_ann_vol
    end
  end

  @doc """
  Generate M-007 synthetic insights from a bar series, but ONLY when
  the carry conditions are satisfied. Returns `[]` when conditions are
  not met — no-op for the caller.

  `opts` passed through to `Seeder.insights_from_bars/2` with sensible
  carry-trade defaults pre-applied (platform, market_class, hold_bars).
  Required opt: `:symbol`.
  """
  @spec insights_for_m007(list(), keyword()) :: list()
  def insights_for_m007(bars, opts) do
    symbol = Keyword.fetch!(opts, :symbol)

    if m007_conditions_met?(bars, opts) do
      seeder_opts =
        [
          platform: Keyword.get(opts, :platform, "oanda_practice"),
          symbol: symbol,
          timeframe: Keyword.get(opts, :timeframe, "1Day"),
          market_class: "forex",
          # Carry trades are held for weeks, not intraday — 20 daily bars
          # (~4 trading weeks) matches real carry deployment horizons.
          hold_bars: Keyword.get(opts, :hold_bars, 20),
          flat_threshold_pct: Keyword.get(opts, :flat_threshold_pct, 0.05)
        ]

      # Re-wrap bars into atom-key shape if they came in as OANDA maps
      # so Seeder.close_of/1 can parse them without crashing.
      normalised = Enum.map(bars, &normalise_bar/1)
      Seeder.insights_from_bars(normalised, seeder_opts)
    else
      []
    end
  end

  @doc "Return the seed version string for M-007 insights."
  def seed_version, do: @seed_version

  # ── Private ───────────────────────────────────────────────────────────────────

  # Annualised realised vol from a series of closes, in percent.
  # Uses log returns; assumes daily bars (252 trading days / year).
  defp realised_vol_pct(closes) do
    log_returns =
      closes
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [prev, curr] -> :math.log(curr / prev) end)

    n = length(log_returns)

    if n < 2 do
      0.0
    else
      mean = Enum.sum(log_returns) / n
      variance = log_returns |> Enum.map(fn r -> (r - mean) ** 2 end) |> Enum.sum()
      daily_vol = :math.sqrt(variance / (n - 1))
      # Annualise: multiply by sqrt(252)
      daily_vol * :math.sqrt(252) * 100.0
    end
  end

  # Extract numeric closes from either OANDA candle maps or Seeder bar maps.
  defp extract_closes(bars) do
    bars
    |> Enum.map(&oanda_close/1)
    |> Enum.filter(&is_number/1)
    |> Enum.filter(&(&1 > 0))
  end

  # OANDA candles nest closes under "mid.c", "bid.c", or "ask.c" as strings.
  # Seeder bars use atom keys %{c: float} or string keys %{"c" => float}.
  defp oanda_close(%{"mid" => %{"c" => c}}), do: parse_float(c)
  defp oanda_close(%{"bid" => %{"c" => c}}), do: parse_float(c)
  defp oanda_close(%{"ask" => %{"c" => c}}), do: parse_float(c)
  defp oanda_close(%{c: c}) when is_number(c), do: c
  defp oanda_close(%{"c" => c}), do: parse_float(c)
  defp oanda_close(_), do: nil

  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v / 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  # Convert an OANDA candle map to the atom-key shape Seeder expects.
  # If the bar is already in atom-key form, pass through unchanged.
  defp normalise_bar(%{c: _} = bar), do: bar

  defp normalise_bar(%{"mid" => %{"c" => c, "o" => o, "h" => h, "l" => l}, "time" => t}),
    do: %{c: parse_float(c), o: parse_float(o), h: parse_float(h), l: parse_float(l), t: t}

  defp normalise_bar(%{"bid" => %{"c" => c, "o" => o, "h" => h, "l" => l}, "time" => t}),
    do: %{c: parse_float(c), o: parse_float(o), h: parse_float(h), l: parse_float(l), t: t}

  defp normalise_bar(%{"c" => _} = bar), do: bar
  defp normalise_bar(bar), do: bar
end
