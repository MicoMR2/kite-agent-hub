defmodule KiteAgentHub.EquityOracle do
  @moduledoc """
  Stock + crypto market-data oracle backed by Alpaca's data API.

  Mirrors the role of `KiteAgentHub.Kite.PriceOracle` (CoinGecko crypto
  for the on-chain side) but uses the user's already-configured Alpaca
  credentials so we get real-time IEX bid/ask/trades for stocks at no
  extra cost. Crypto goes through Alpaca's `/v1beta3/crypto/us` venue
  which collapses our two oracle paths into one source of truth.

  Functions return `{:ok, term}` on success or `{:error, reason}` on
  any failure (missing creds, transport, 4xx, etc). Failure modes
  collapse to a normalized atom so callers can pattern-match without
  caring about the specific HTTP status.

  Symbol formats:
    * Stocks      — `"AAPL"`, `"SPY"` (uppercase, 1-8 chars)
    * Options     — full OCC contract symbol via the AlpacaClient
                    options endpoints (not exposed here yet)
    * Crypto      — `"BTC/USD"` slash form (modern) or `"BTCUSD"`
                    (legacy auto-rewritten)
  """

  require Logger

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  @doc "Fetch the latest snapshot for one stock. Wraps `snapshots/2`."
  def stock_snapshot(org_id, symbol) when is_binary(symbol) do
    case stock_snapshots(org_id, [symbol]) do
      {:ok, %{} = map} -> {:ok, Map.get(map, symbol)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Latest snapshots for many stock symbols. Returns
  `{:ok, %{symbol => %{price, bid, ask, ...}}}` on success — the
  shape is normalized below so callers do not have to know Alpaca's
  raw `latestTrade.p` / `latestQuote.bp` field layout.
  """
  def stock_snapshots(org_id, symbols) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      case AlpacaClient.snapshots(key, secret, symbols) do
        {:ok, raw} when is_map(raw) ->
          # AlpacaClient.snapshots already returns just the prices map
          # (see extract_latest_trade_prices). Normalize each entry to
          # a friendlier shape with bid/ask if we have the room — this
          # function may be replaced with a richer schema once we wire
          # latest_quotes alongside.
          {:ok,
           Map.new(raw, fn {sym, price} ->
             {sym, %{price: price}}
           end)}

        {:error, _} = err ->
          err
      end
    end)
  end

  @doc "Latest bid/ask for one or many stocks via /v2/stocks/quotes/latest."
  def stock_latest_quotes(org_id, symbols) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.latest_quotes(key, secret, symbols)
    end)
  end

  @doc "Latest trade prints for stocks via /v2/stocks/trades/latest."
  def stock_latest_trades(org_id, symbols) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.latest_trades(key, secret, symbols)
    end)
  end

  @doc """
  Historical OHLC bars for one stock symbol. Same `timeframe` strings
  Alpaca accepts (`1Min`, `5Min`, `1Hour`, `1Day`, `1Week`, `1Month`).
  Returns `{:ok, [bar_map]}` with the raw Alpaca bar shape (o/h/l/c/v/t).
  """
  def stock_bars(org_id, symbol, timeframe \\ "1Day", limit \\ 50) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.bars(key, secret, symbol, timeframe, limit)
    end)
  end

  @doc """
  Latest crypto snapshot bundle (latest trade/quote, minute/daily/prev
  bars). Symbols accepted as `"BTC/USD"` or `"BTCUSD"` — both normalize
  to the slash form Alpaca's v1beta3 endpoints require.
  """
  def crypto_snapshots(org_id, symbols) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.crypto_snapshots(key, secret, symbols)
    end)
  end

  @doc "Latest crypto bid/ask quotes via /v1beta3/crypto/us/latest/quotes."
  def crypto_latest_quotes(org_id, symbols) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.crypto_latest_quotes(key, secret, symbols)
    end)
  end

  @doc """
  Historical OHLCV bars for one or many crypto symbols via Alpaca's
  `/v1beta3/crypto/us/bars` endpoint.

  Accepts symbols in slash form (`"BTC/USD"`) or legacy no-slash form
  (`"BTCUSD"`) — both are normalised before the request. Returns:

      {:ok, %{"BTC/USD" => [%{t: iso8601, o: float, h: float, l: float, c: float, v: float}]}}

  `timeframe` mirrors the strings `EquityOracle.stock_bars/4` accepts
  (`"1Day"`, `"1Hour"`, `"15Min"`, etc.). `limit` is the per-symbol bar
  count.

  This replaces the snapshot-bar fallback in `KciSeederWorker` which only
  returned 1-2 data points (minuteBar/dailyBar). A direct bars call gives
  a full historical series suitable for the Seeder's backtest walk.
  """
  def crypto_bars(org_id, symbols, timeframe \\ "1Day", limit \\ 50) when is_list(symbols) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.crypto_bars(key, secret, symbols, timeframe, limit)
    end)
  end

  @doc """
  Historical Benzinga news for sentiment analysis. Pair with
  `:symbols`, `:start`, `:end`, and `:limit` (1..50). Returns
  `{:ok, [article]}` with the raw article shape.
  """
  def news(org_id, opts \\ []) do
    with_alpaca(org_id, fn key, secret ->
      AlpacaClient.news(key, secret, opts)
    end)
  end

  # Run `fun.(key_id, secret)` with the org's Alpaca credentials.
  # Collapses missing-cred / decrypt errors into a normalized atom so
  # callers do not have to handle the raw Credentials shape.
  defp with_alpaca(org_id, fun) when is_function(fun, 2) do
    case Credentials.fetch_secret(org_id, :alpaca) do
      {:ok, {key_id, secret}} ->
        try do
          fun.(key_id, secret)
        rescue
          e ->
            Logger.error("EquityOracle call crashed: #{inspect(e)}")
            {:error, :exception}
        end

      _ ->
        {:error, :not_configured}
    end
  end
end
