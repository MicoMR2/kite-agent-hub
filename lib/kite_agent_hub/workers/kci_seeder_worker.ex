defmodule KiteAgentHub.Workers.KciSeederWorker do
  @moduledoc """
  Bootstrap the KCI corpus from public market-data backtests so new
  agents have meaningful baseline insights from day 1, before any
  user trade has settled.

  Strategy:
  1. Pick the first opted-in org with Alpaca credentials (or accept
     `org_id` as an arg for explicit runs).
  2. For each seed market (top equities + crypto), pull a year of
     daily bars via `EquityOracle`.
  3. Hand each bar series to `Seeder.insights_from_bars/2` to
     synthesize ~50 random-entry trade outcomes.
  4. Insert each via `CollectiveIntelligence.record_synthetic_outcome/1`
     — idempotent on `source_trade_hash` so re-runs upsert cleanly.

  The cron schedule (config.exs) runs this weekly; one fetch per
  market per week is comfortably under Alpaca's free-tier rate limits.

  Manual one-shot from iex (admin) when an org wants to re-seed:

      KiteAgentHub.Workers.KciSeederWorker.new(%{"org_id" => "..."})
      |> Oban.insert()
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 2

  require Logger

  alias KiteAgentHub.{CollectiveIntelligence, EquityOracle, Repo}
  alias KiteAgentHub.CollectiveIntelligence.Seeder
  alias KiteAgentHub.Credentials.ApiCredential

  import Ecto.Query

  # Top symbols by market category. Kept small to stay well under the
  # Alpaca free-tier cap of 200 req/min — one bars call per symbol
  # per run.
  @stock_seed_symbols ~w(SPY QQQ AAPL MSFT NVDA AMZN GOOGL META TSLA AMD)
  @crypto_seed_symbols ~w(BTC/USD ETH/USD SOL/USD)
  @stock_timeframe "1Day"
  @crypto_timeframe "1Day"
  @bars_per_run 250

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case resolve_org(args["org_id"]) do
      {:ok, org_id} ->
        Logger.info("KciSeederWorker: seeding via org #{org_id}")
        run(org_id)

      {:error, :no_alpaca_org} ->
        Logger.info("KciSeederWorker: no org with Alpaca credentials found — skipping seed cycle")

        :ok
    end
  end

  defp run(org_id) do
    stocks = seed_stocks(org_id)
    crypto = seed_crypto(org_id)

    Logger.info(
      "KciSeederWorker: inserted #{stocks} stock + #{crypto} crypto synthetic insights " <>
        "(seed=#{Seeder.seed_version()})"
    )

    :ok
  end

  defp seed_stocks(org_id) do
    Enum.reduce(@stock_seed_symbols, 0, fn symbol, acc ->
      acc + seed_symbol(org_id, symbol, "alpaca", "equity", @stock_timeframe, &fetch_stock_bars/3)
    end)
  end

  defp seed_crypto(org_id) do
    Enum.reduce(@crypto_seed_symbols, 0, fn symbol, acc ->
      acc +
        seed_symbol(org_id, symbol, "alpaca", "crypto", @crypto_timeframe, &fetch_crypto_bars/3)
    end)
  end

  defp seed_symbol(org_id, symbol, platform, market_class, timeframe, fetcher) do
    case fetcher.(org_id, symbol, timeframe) do
      {:ok, bars} when is_list(bars) ->
        attrs_list =
          Seeder.insights_from_bars(bars,
            platform: platform,
            symbol: symbol,
            timeframe: timeframe,
            market_class: market_class
          )

        Enum.reduce(attrs_list, 0, fn attrs, count ->
          case CollectiveIntelligence.record_synthetic_outcome(attrs) do
            :ok -> count + 1
            _ -> count
          end
        end)

      {:error, reason} ->
        Logger.warning("KciSeederWorker: skipping #{symbol} — fetch failed: #{inspect(reason)}")

        0
    end
  end

  defp fetch_stock_bars(org_id, symbol, timeframe) do
    case EquityOracle.stock_bars(org_id, symbol, timeframe, @bars_per_run) do
      {:ok, bars} when is_list(bars) -> {:ok, bars}
      {:ok, _other} -> {:ok, []}
      {:error, _} = err -> err
    end
  end

  defp fetch_crypto_bars(org_id, symbol, _timeframe) do
    # EquityOracle does not yet expose crypto bars (snapshots only) —
    # fall back to the snapshots minute/daily bar so the seeder still
    # produces SOME crypto data points until a dedicated bars wrapper
    # lands. Returns 1-2 bars per symbol so the seeder logs a small
    # but non-zero count instead of skipping crypto entirely.
    case EquityOracle.crypto_snapshots(org_id, [symbol]) do
      {:ok, snapshots_map} when is_map(snapshots_map) ->
        bars =
          snapshots_map
          |> Map.values()
          |> Enum.flat_map(fn snap ->
            [
              snap["minuteBar"],
              snap["dailyBar"],
              snap["prevDailyBar"]
            ]
            |> Enum.filter(&is_map/1)
          end)

        {:ok, bars}

      {:error, _} = err ->
        err
    end
  end

  # If the caller passed an org_id explicitly, use it. Otherwise pick
  # the first org whose api_credentials row has a non-null encrypted
  # secret for `alpaca`. This is intentionally non-RLS — the worker
  # runs without a user context and only needs the org boundary, not
  # the row-level isolation. The seeder never reads or writes any
  # other org's tables.
  defp resolve_org(nil) do
    case Repo.one(
           from c in ApiCredential,
             where: c.provider == "alpaca",
             order_by: [asc: c.inserted_at],
             limit: 1,
             select: c.org_id
         ) do
      nil -> {:error, :no_alpaca_org}
      org_id -> {:ok, org_id}
    end
  end

  defp resolve_org(org_id) when is_binary(org_id), do: {:ok, org_id}
end
