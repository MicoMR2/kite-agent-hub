defmodule KiteAgentHub.CollectiveIntelligence.Seeder do
  @moduledoc """
  Synthetic public-data backtester that bootstraps the Kite Collective
  Intelligence corpus before any real user trade has settled. Lets new
  agents read meaningful baseline win-rate / sample-size insights from
  day 1 — instead of an empty `/api/v1/collective-intelligence` payload.

  The math is deliberately simple: for each market we walk a series of
  historical bars and simulate a "buy at close of bar i, sell at close
  of bar i+hold" trade. Outcome is bucketed against
  `CollectiveIntelligence.outcome_bucket` semantics (profit / loss /
  flat). A short hold (~10 bars) on daily timeframes lets one fetch
  produce ~30-50 simulated outcomes per market.

  Determinism: every synthetic insight uses a stable
  `source_trade_hash` derived from
  `(seed_version, platform, symbol, timeframe, bar_index)` so reruns
  insert with `on_conflict: :nothing` and never duplicate rows.

  Privacy: every synthetic row carries a public seed `source_org_hash`
  derived from `("seed", seed_version)` — distinct from any real org
  hash, and the seed corpus can be purged independently if a future
  policy change requires it.
  """

  alias KiteAgentHub.CollectiveIntelligence

  @seed_version "public-seed-v1-2026-05"

  @doc """
  Generate insight attrs maps from a list of bars. Pure — caller is
  responsible for inserting via `CollectiveIntelligence.record_synthetic_outcome/1`.

  ## Args
    * `bars` — list of bar maps (Alpaca shape: `%{"o", "h", "l", "c", "t", ...}`)
    * `opts`
      * `:platform` — `"alpaca" | "oanda_practice" | ...` (required)
      * `:symbol`   — symbol string (required, drives the hash)
      * `:timeframe` — bar timeframe string, e.g. "1Day" (required)
      * `:market_class` — `"equity" | "crypto" | "forex"` (required)
      * `:hold_bars`   — how many bars to hold; default 10
      * `:flat_threshold_pct` — outcome counts as "flat" when |Δ%| < this. Default 0.1
      * `:notional_bucket` — string bucket for synthetic notional. Default "100_to_999"
  """
  def insights_from_bars(bars, opts) when is_list(bars) do
    platform = Keyword.fetch!(opts, :platform)
    symbol = Keyword.fetch!(opts, :symbol)
    timeframe = Keyword.fetch!(opts, :timeframe)
    market_class = Keyword.fetch!(opts, :market_class)
    hold = Keyword.get(opts, :hold_bars, 10)
    flat_pct = Keyword.get(opts, :flat_threshold_pct, 0.1)
    notional = Keyword.get(opts, :notional_bucket, "100_to_999")

    closes = bars |> Enum.map(&close_of/1) |> Enum.filter(&is_number/1)

    # Need at least hold+1 bars to form one entry/exit pair.
    if length(closes) < hold + 1 do
      []
    else
      indexed = Enum.with_index(closes)
      max_i = length(closes) - hold - 1

      Enum.flat_map(0..max_i, fn i ->
        entry = Enum.at(closes, i)
        exit_price = Enum.at(closes, i + hold)
        change_pct = (exit_price - entry) / entry * 100

        # Build BOTH a synthetic long and a synthetic short for each
        # entry, so the corpus reflects directional reality (not just
        # that "buy works"). The short row's outcome is the inverse.
        [
          synthetic_attrs(:long, change_pct,
            platform: platform,
            symbol: symbol,
            timeframe: timeframe,
            market_class: market_class,
            bar_index: i,
            flat_pct: flat_pct,
            notional: notional,
            hold_bars: hold,
            ts: timestamp_of(Enum.at(bars, i + hold))
          ),
          synthetic_attrs(:short, -change_pct,
            platform: platform,
            symbol: symbol,
            timeframe: timeframe,
            market_class: market_class,
            bar_index: i,
            flat_pct: flat_pct,
            notional: notional,
            hold_bars: hold,
            ts: timestamp_of(Enum.at(bars, i + hold))
          )
        ]
      end)
    end
  end

  defp synthetic_attrs(direction, change_pct, opts) do
    platform = opts[:platform]
    symbol = opts[:symbol]
    timeframe = opts[:timeframe]
    market_class = opts[:market_class]
    bar_index = opts[:bar_index]
    flat_pct = opts[:flat_pct]
    notional = opts[:notional]
    hold_bars = opts[:hold_bars]
    ts = opts[:ts]

    side =
      case {market_class, direction} do
        {"prediction", :long} -> "yes"
        {"prediction", :short} -> "no"
        {_, :long} -> "long"
        {_, :short} -> "short"
      end

    action = if direction == :long, do: "buy", else: "sell"

    outcome =
      cond do
        abs(change_pct) < flat_pct -> "flat"
        change_pct > 0 -> "profit"
        true -> "loss"
      end

    %{
      source_trade_hash:
        CollectiveIntelligence.seed_hash(
          "synthetic",
          "#{@seed_version}|#{platform}|#{symbol}|#{timeframe}|#{bar_index}|#{direction}"
        ),
      source_org_hash: CollectiveIntelligence.seed_hash("seed", @seed_version),
      agent_type: "synthetic",
      platform: platform,
      market_class: market_class,
      side: side,
      action: action,
      status: "settled",
      outcome_bucket: outcome,
      notional_bucket: notional,
      hold_time_bucket: hold_bucket(timeframe, hold_bars),
      observed_week: week_of(ts)
    }
  end

  # Bars come back in two shapes depending on the source:
  #   - AlpacaClient.bars/5 parses to atom keys: %{c: 187.4, t: "..."}
  #   - Raw v2/stocks/bars JSON has string keys: %{"c" => 187.4, "t" => "..."}
  # Crypto-snapshot bars also use string keys. Tolerate both so the
  # seeder works regardless of which fetcher produced the series.
  defp close_of(%{c: c}) when is_number(c), do: c
  defp close_of(%{"c" => c}) when is_number(c), do: c

  defp close_of(%{c: c}) when is_binary(c) do
    case Float.parse(c) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp close_of(%{"c" => c}) when is_binary(c) do
    case Float.parse(c) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp close_of(_), do: nil

  defp timestamp_of(%{t: t}) when is_binary(t), do: t
  defp timestamp_of(%{"t" => t}) when is_binary(t), do: t
  defp timestamp_of(_), do: nil

  defp week_of(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _} -> dt |> DateTime.to_date() |> Date.beginning_of_week(:monday)
      _ -> Date.utc_today() |> Date.beginning_of_week(:monday)
    end
  end

  defp week_of(_), do: Date.utc_today() |> Date.beginning_of_week(:monday)

  # Approximate the hold time given the bar timeframe + bar count, then
  # bucket it the same way real trades are bucketed in
  # CollectiveIntelligence.hold_time_bucket/1.
  defp hold_bucket(timeframe, hold_bars) do
    seconds = hold_bars * timeframe_seconds(timeframe)

    cond do
      seconds < 5 * 60 -> "under_5m"
      seconds < 60 * 60 -> "5m_to_1h"
      seconds < 24 * 60 * 60 -> "1h_to_1d"
      true -> "over_1d"
    end
  end

  defp timeframe_seconds("1Min"), do: 60
  defp timeframe_seconds("5Min"), do: 300
  defp timeframe_seconds("15Min"), do: 900
  defp timeframe_seconds("30Min"), do: 1_800
  defp timeframe_seconds("1Hour"), do: 3_600
  defp timeframe_seconds("4Hour"), do: 14_400
  defp timeframe_seconds("1Day"), do: 86_400
  defp timeframe_seconds("1Week"), do: 604_800
  defp timeframe_seconds(_), do: 86_400

  @doc "Stable seed version string. Bumped when the simulation logic changes."
  def seed_version, do: @seed_version
end
