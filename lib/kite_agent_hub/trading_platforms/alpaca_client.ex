defmodule KiteAgentHub.TradingPlatforms.AlpacaClient do
  @moduledoc """
  Alpaca Markets Paper Trading API client.

  Auth: APCA-API-KEY-ID + APCA-API-SECRET-KEY headers.
  Paper trading base: https://paper-api.alpaca.markets

  Usage:
    {:ok, {key_id, secret}} = Credentials.fetch_secret(org_id, :alpaca)
    {:ok, account} = AlpacaClient.account(key_id, secret)
    {:ok, positions} = AlpacaClient.positions(key_id, secret)
    {:ok, history} = AlpacaClient.portfolio_history(key_id, secret)
  """

  @paper_base "https://paper-api.alpaca.markets"
  @live_base "https://api.alpaca.markets"
  # Market data API is the same host for paper + live — Alpaca only
  # splits the trading endpoints by env, not the data endpoints.
  @data_base "https://data.alpaca.markets"

  # Pick the Alpaca REST base URL for a given env.
  # Default "paper" matches the pre-env-toggle behavior so callers
  # that haven't been updated yet keep working on the sandbox.
  defp base_url("live"), do: @live_base
  defp base_url(_), do: @paper_base

  @doc "Fetch account summary — equity, cash, buying_power, portfolio_value."
  def account(key_id, secret, env \\ "paper") do
    get("/v2/account", key_id, secret, env)
    |> parse_account()
  end

  @doc "Fetch open positions. Returns list of position maps."
  def positions(key_id, secret, env \\ "paper") do
    case get("/v2/positions", key_id, secret, env) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &parse_position/1)}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc """
  Fetch asset metadata for a single symbol. Used by the worker's short
  pre-flight check (`easy_to_borrow`) and any future fractional-only
  filters (`fractionable`). Returns:

      {:ok, %{symbol, tradable, shortable, easy_to_borrow,
              fractionable, marginable, options_enabled}}

  Or `{:error, reason}` if the symbol is unknown or the account is
  unauthorized for asset metadata.
  """
  def asset(key_id, secret, symbol, env \\ "paper") do
    case get("/v2/assets/#{symbol}", key_id, secret, env) do
      {:ok, body} when is_map(body) ->
        {:ok,
         %{
           symbol: body["symbol"],
           tradable: parse_bool(body["tradable"]),
           shortable: parse_bool(body["shortable"]),
           easy_to_borrow: parse_bool(body["easy_to_borrow"]),
           fractionable: parse_bool(body["fractionable"]),
           marginable: parse_bool(body["marginable"]),
           options_enabled: body["attributes"] |> List.wrap() |> Enum.member?("options_enabled")
         }}

      {:ok, _} ->
        {:error, "alpaca asset response not a map"}

      err ->
        err
    end
  end

  @doc """
  Fetch portfolio equity history for sparkline chart.
  Returns {:ok, [%{t: unix_ts, v: equity_float}]} or {:error, reason}.
  """
  def portfolio_history(key_id, secret, period \\ "1M", timeframe \\ "1D", env \\ "paper") do
    case get(
           "/v2/account/portfolio/history?period=#{period}&timeframe=#{timeframe}",
           key_id,
           secret,
           env
         ) do
      {:ok, %{"timestamp" => ts, "equity" => equity}} when is_list(ts) ->
        points =
          Enum.zip(ts, equity)
          |> Enum.reject(fn {_t, v} -> is_nil(v) end)
          |> Enum.map(fn {t, v} -> %{t: t, v: v} end)

        {:ok, points}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Fetch recent filled orders. Returns {:ok, [order_map]} or {:error, reason}.
  Each order: %{id, symbol, side, qty, filled_qty, filled_avg_price, status, submitted_at}
  """
  def orders(key_id, secret, limit \\ 20, env \\ "paper") do
    list_orders(key_id, secret, "filled", limit, env)
  end

  @doc """
  Fetch orders filtered by status ("open", "closed", "all", or any
  Alpaca-supported status). Used by `/api/v1/broker/orders` to surface
  live open broker orders so agents can catch ghost orders BEFORE
  queueing a same-symbol entry and hitting a wash-block.
  """
  def list_orders(key_id, secret, status \\ "open", limit \\ 50, env \\ "paper") do
    path = "/v2/orders?status=#{status}&limit=#{limit}&direction=desc"

    case get(path, key_id, secret, env) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &parse_order/1)}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc """
  Fetch a single order by Alpaca order id. Used by AlpacaSettlementWorker
  to poll fill status for open trades. Routes to paper or live based on
  the credential env.

  Returns {:ok, %{id, symbol, side, qty, filled_qty, filled_avg_price,
  status, submitted_at}} or {:error, reason}.
  """
  def get_order(key_id, secret, order_id, env \\ "paper") do
    case get("/v2/orders/#{order_id}", key_id, secret, env) do
      {:ok, body} when is_map(body) -> {:ok, parse_order(body)}
      err -> err
    end
  end

  @doc """
  Cancel a single open Alpaca order by id (DELETE /v2/orders/{id}).

  Alpaca returns 204 on success, 422 if the order is already in a
  terminal state (filled/cancelled/rejected/expired) — we normalize
  that to {:ok, :already_terminal} so the caller can treat it as an
  idempotent no-op. 404 is also idempotent: the order doesn't exist
  on Alpaca's side anymore, so from the hub's perspective there's
  nothing to cancel.
  """
  def cancel_order(key_id, secret, order_id, env \\ "paper") do
    delete("/v2/orders/#{order_id}", key_id, secret, env)
  end

  @doc """
  Fetch recent OHLCV bars for a symbol from the Alpaca Market Data API.

  symbol     — e.g. "AAPL", "SPY", "TSLA"
  timeframe  — Alpaca bar timeframe ("1Day", "1Hour", "15Min", etc.). Default "1Day".
  limit      — number of bars (max 10000). Default 50.

  The data API host is shared between paper and live, so this does NOT
  take an env arg — the same key authenticates both. Returns:
    {:ok, [%{t: iso8601, o: float, h: float, l: float, c: float, v: integer}]}
  or {:error, reason}. Empty list if Alpaca returns no bars.
  """
  def bars(key_id, secret, symbol, timeframe \\ "1Day", limit \\ 50) do
    bars_with_retry(key_id, secret, symbol, timeframe, limit, 0)
  end

  @doc """
  Fetch latest-trade snapshots for one or more symbols from
  `/v2/stocks/snapshots?symbols=...`. Returns a map of
  `%{"AAPL" => 187.42, ...}` with only the symbols that came back
  with a usable `latestTrade.p`. Symbols without a snapshot (or
  without a valid latest trade price) are simply absent from the
  map — callers fall back to their bar-close last_price for those.

  Symbols are re-validated against the same whitelist regex
  ScoreController uses before being interpolated into the URL, so
  even a direct caller cannot smuggle raw input to Alpaca (CyberSec
  pre-build guardrail, msg 6395).
  """
  @ticker_regex ~r/\A[A-Z0-9]{1,8}\z/

  def snapshots(key_id, secret, symbols) when is_list(symbols) do
    clean =
      symbols
      |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.upcase()))
      |> Enum.filter(&Regex.match?(@ticker_regex, &1))
      |> Enum.uniq()

    case clean do
      [] ->
        {:ok, %{}}

      list ->
        path = "/v2/stocks/snapshots?symbols=#{Enum.join(list, ",")}&feed=iex"
        url = @data_base <> path

        headers = [
          {"APCA-API-KEY-ID", key_id},
          {"APCA-API-SECRET-KEY", secret}
        ]

        case Req.get(url, headers: headers, retry: false) do
          {:ok, %{status: 200, body: body}} when is_map(body) ->
            {:ok, extract_latest_trade_prices(body)}

          {:ok, %{status: 200, body: _}} ->
            {:ok, %{}}

          {:ok, %{status: 401}} ->
            {:error, :unauthorized}

          {:ok, %{status: status}} ->
            {:error, "alpaca snapshots #{status}"}

          {:error, reason} ->
            {:error, "alpaca snapshots HTTP: #{inspect(reason)}"}
        end
    end
  end

  defp extract_latest_trade_prices(body) do
    Enum.reduce(body, %{}, fn {sym, payload}, acc ->
      price =
        case payload do
          %{"latestTrade" => %{"p" => p}} when is_number(p) and p > 0 -> p
          _ -> nil
        end

      if price, do: Map.put(acc, sym, price), else: acc
    end)
  end

  # Alpaca's free tier caps the data API at 200 req/min. Under a burst
  # of batch scoring, a single 429 would fail the whole ticker. Retry
  # up to 2 times honoring Retry-After (capped at 10s so we don't hang
  # the caller). After that, surface the 429 so the caller can serialize
  # or back off at a higher level.
  @max_bars_retries 2
  @max_retry_after_ms 10_000

  defp bars_with_retry(key_id, secret, symbol, timeframe, limit, attempt) do
    require Logger

    # Alpaca's data API will silently return only the most recent bar
    # (or a tiny window) when `start` is omitted on the free tier —
    # SMA-20 collapses to last_price, change_5d/20d_pct come back 0.0,
    # and every downstream score is understated. Always pass an
    # explicit `start` sized to comfortably cover `limit` bars for
    # the requested timeframe.
    start_iso = bars_start(timeframe, limit)

    path =
      "/v2/stocks/#{symbol}/bars?timeframe=#{timeframe}&limit=#{limit}&start=#{start_iso}&adjustment=raw&feed=iex"

    url = @data_base <> path

    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 200, body: %{"bars" => bars}}} when is_list(bars) ->
        {:ok, Enum.map(bars, &parse_bar/1)}

      {:ok, %{status: 200, body: _}} ->
        {:ok, []}

      {:ok, %{status: 401}} ->
        Logger.warning("Alpaca data API: 401 for #{symbol}")
        {:error, :unauthorized}

      {:ok, %{status: 429, headers: resp_headers}} when attempt < @max_bars_retries ->
        wait_ms = parse_retry_after(resp_headers, attempt)

        Logger.info(
          "Alpaca data API: 429 for #{symbol}, sleeping #{wait_ms}ms (attempt #{attempt + 1}/#{@max_bars_retries})"
        )

        Process.sleep(wait_ms)
        bars_with_retry(key_id, secret, symbol, timeframe, limit, attempt + 1)

      {:ok, %{status: 429}} ->
        Logger.warning("Alpaca data API: 429 for #{symbol}, retries exhausted")
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        Logger.warning("Alpaca data API: HTTP #{status} for #{symbol}")
        {:error, "alpaca data #{status}"}

      {:error, reason} ->
        Logger.error("Alpaca data API: request failed for #{symbol}: #{inspect(reason)}")
        {:error, "alpaca data HTTP: #{inspect(reason)}"}
    end
  end

  # Pick a `start` ISO-8601 timestamp that guarantees at least `limit`
  # bars fit inside the window for the given timeframe. The 2x
  # multiplier on daily covers weekends/holidays; intraday frames use
  # a slightly bigger buffer for market-hour gaps.
  defp bars_start(timeframe, limit) do
    seconds_per_bar =
      case timeframe do
        "1Min" -> 60
        "5Min" -> 5 * 60
        "15Min" -> 15 * 60
        "1Hour" -> 3600
        "1Day" -> 86_400
        _ -> 86_400
      end

    multiplier = if timeframe == "1Day", do: 2.0, else: 3.0
    window_seconds = trunc(seconds_per_bar * limit * multiplier)

    DateTime.utc_now()
    |> DateTime.add(-window_seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> URI.encode_www_form()
  end

  # Retry-After can be a decimal-seconds string or an HTTP-date. Alpaca
  # sends seconds. Fall back to exponential backoff (1s, 2s) if the
  # header is missing or unparseable.
  defp parse_retry_after(headers, attempt) do
    raw =
      Enum.find_value(headers, fn
        {"retry-after", v} -> v
        {"Retry-After", v} -> v
        _ -> nil
      end)

    seconds =
      case raw do
        nil ->
          nil

        v when is_list(v) ->
          v |> List.first() |> parse_retry_after_value()

        v when is_binary(v) ->
          parse_retry_after_value(v)

        _ ->
          nil
      end

    case seconds do
      n when is_number(n) and n > 0 -> min(trunc(n * 1000), @max_retry_after_ms)
      _ -> min((attempt + 1) * 1000, @max_retry_after_ms)
    end
  end

  defp parse_retry_after_value(v) when is_binary(v) do
    case Float.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_retry_after_value(_), do: nil

  defp parse_bar(b) do
    %{
      t: b["t"],
      o: parse_float(b["o"]),
      h: parse_float(b["h"]),
      l: parse_float(b["l"]),
      c: parse_float(b["c"]),
      v: b["v"] || 0
    }
  end

  @doc """
  Place a market order on Alpaca.

  symbol  — e.g. "ETHUSD", "BTCUSD", "SPY"
  qty     — number of shares/units (string or float)
  side    — "buy" or "sell"
  env     — "paper" (default, paper-api.alpaca.markets) or "live"
            (api.alpaca.markets). The catch-all in base_url/1 routes
            unknown values to paper for safety.

  Returns {:ok, %{id, symbol, side, qty, status}} or {:error, reason}.
  """
  def place_order(key_id, secret, symbol, qty, side \\ "buy", env \\ "paper", opts \\ []) do
    body = order_body(symbol, qty, side, opts)

    post("/v2/orders", body, key_id, secret, env)
    |> parse_placed_order()
  end

  # OCC option contract symbol: <root 1-6><YYMMDD><C|P><strike8>.
  # e.g. AAPL260117C00100000 — Apple Jan 17, 2026 $100 call.
  @option_symbol ~r/\A[A-Z]{1,6}\d{6}[CP]\d{8}\z/

  @doc false
  def options_symbol?(symbol) when is_binary(symbol), do: Regex.match?(@option_symbol, symbol)
  def options_symbol?(_), do: false

  @doc false
  def order_body(symbol, qty, side \\ "buy", opts \\ []) do
    opts = normalize_opts(opts)
    order_type = normalize_order_type(opts["order_type"] || opts["type"] || "market")
    options? = options_symbol?(symbol)

    # Alpaca docs: "entering a value for either parameter automatically
    # nullifies the other." When the agent supplies notional (USD-based
    # fractional / crypto orders), send notional and omit qty. Options
    # never accept notional, so options always fall through to qty.
    notional = if options?, do: nil, else: opts["notional"]

    base = %{
      "symbol" => symbol,
      "side" => side,
      "type" => order_type,
      "time_in_force" => normalize_time_in_force(opts["time_in_force"], symbol)
    }

    base =
      if notional do
        Map.put(base, "notional", to_string(notional))
      else
        Map.put(base, "qty", normalize_qty(qty, options?))
      end

    base
    |> put_optional("limit_price", opts["limit_price"] || opts["price"])
    |> put_optional("stop_price", opts["stop_price"])
    |> put_optional("trail_price", opts["trail_price"])
    |> put_optional("trail_percent", opts["trail_percent"])
    # Alpaca rejects options orders that include `extended_hours` at all.
    # Strip the field for OCC symbols even if the agent passed it.
    |> put_optional_unless_options("extended_hours", parse_bool(opts["extended_hours"]), options?)
    |> put_optional("order_class", normalize_order_class(opts["order_class"]))
    |> put_optional("take_profit", nested_take_profit(opts))
    |> put_optional("stop_loss", nested_stop_loss(opts))
    |> put_optional("client_order_id", opts["client_order_id"])
  end

  # Options orders must use whole-number qty. Truncate fractional input
  # rather than letting Alpaca 422 the order — agents typically pass
  # `contracts: 1` already, this is a defensive guard.
  defp normalize_qty(qty, true = _options?) do
    case qty |> to_string() |> Float.parse() do
      {f, _} -> f |> trunc() |> max(1) |> to_string()
      :error -> to_string(qty)
    end
  end

  defp normalize_qty(qty, _equity?), do: to_string(qty)

  defp put_optional_unless_options(map, _key, _value, true), do: map
  defp put_optional_unless_options(map, key, value, false), do: put_optional(map, key, value)

  # Alpaca's crypto venue rejects time_in_force=day with
  # `code=42210000 "invalid crypto time_in_force"`. Crypto only accepts
  # gtc or ioc. Equities accept day, gtc, or ioc. Use gtc for crypto so
  # the order survives across the (always-open) crypto session and day
  # for equities so it expires at market close like a normal stock
  # order. Symbol list mirrors the @alpaca_markets canonical no-dash
  # crypto names — KAH-side dashed forms (BTC-USDC etc.) get mapped to
  # these via @alpaca_symbol_map before reaching place_order/6.
  defp time_in_force_for(symbol) when symbol in ["BTCUSD", "ETHUSD", "SOLUSD"], do: "gtc"
  defp time_in_force_for(_symbol), do: "day"

  defp normalize_time_in_force(nil, symbol), do: time_in_force_for(symbol)

  defp normalize_time_in_force(tif, _symbol) when is_binary(tif),
    do: tif |> String.trim() |> String.downcase()

  defp normalize_time_in_force(tif, _symbol), do: tif |> to_string() |> String.downcase()

  defp normalize_order_type(type) when is_binary(type),
    do: type |> String.trim() |> String.downcase()

  defp normalize_order_type(type), do: type |> to_string() |> String.downcase()

  defp normalize_order_class(nil), do: nil

  defp normalize_order_class(order_class) when is_binary(order_class),
    do: order_class |> String.trim() |> String.downcase()

  defp normalize_order_class(order_class), do: to_string(order_class)

  defp nested_take_profit(%{"take_profit" => take_profit}) when is_map(take_profit),
    do: stringify_map(take_profit)

  defp nested_take_profit(%{"take_profit_limit_price" => price}) when not is_nil(price),
    do: %{"limit_price" => price}

  defp nested_take_profit(_opts), do: nil

  defp nested_stop_loss(%{"stop_loss" => stop_loss}) when is_map(stop_loss),
    do: stringify_map(stop_loss)

  defp nested_stop_loss(opts) do
    %{}
    |> put_optional("stop_price", opts["stop_loss_stop_price"] || opts["stop_loss_price"])
    |> put_optional("limit_price", opts["stop_loss_limit_price"])
    |> case do
      map when map == %{} -> nil
      map -> map
    end
  end

  defp normalize_opts(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_opts(opts) when is_list(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_opts(_opts), do: %{}

  defp stringify_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp parse_bool(nil), do: nil
  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  # ── Private ───────────────────────────────────────────────────────────────────

  defp post(path, body, key_id, secret, env) do
    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.post(base_url(env) <> path, json: body, headers: headers) do
      {:ok, %{status: s, body: resp_body}} when s in [200, 201] ->
        {:ok, resp_body}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, "alpaca #{status}: #{inspect(resp_body)}"}

      {:error, reason} ->
        {:error, "alpaca HTTP: #{inspect(reason)}"}
    end
  end

  defp parse_placed_order({:ok, o}) do
    {:ok,
     %{
       id: o["id"],
       symbol: o["symbol"],
       side: o["side"],
       qty: parse_float(o["qty"]),
       status: o["status"]
     }}
  end

  defp parse_placed_order(err), do: err

  defp delete(path, key_id, secret, env) do
    require Logger

    url = base_url(env) <> path

    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.delete(url, headers: headers, retry: false) do
      {:ok, %{status: s}} when s in [200, 204] ->
        {:ok, :cancelled}

      {:ok, %{status: 404}} ->
        Logger.info("Alpaca DELETE #{path} — 404, treating as already gone")
        {:ok, :already_terminal}

      {:ok, %{status: 422, body: body}} ->
        Logger.info("Alpaca DELETE #{path} — 422 (already terminal): #{inspect(body)}")
        {:ok, :already_terminal}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        {:error, "alpaca #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "alpaca HTTP: #{inspect(reason)}"}
    end
  end

  defp get(path, key_id, secret, env) do
    require Logger

    key_prefix = if is_binary(key_id), do: String.slice(key_id, 0..3), else: "nil"
    has_secret = is_binary(secret) and secret != ""
    url = base_url(env) <> path
    Logger.info("Alpaca GET #{url} env=#{env} key_prefix=#{key_prefix} has_secret=#{has_secret}")

    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        Logger.info("Alpaca: 200 OK for #{path}")
        {:ok, body}

      {:ok, %{status: 401}} ->
        Logger.warning("Alpaca: 401 Unauthorized for #{path} — key_prefix=#{key_prefix}")
        {:error, :unauthorized}

      {:ok, %{status: 404}} ->
        Logger.info("Alpaca: 404 for #{path} — returning empty")
        {:error, :not_found}

      {:ok, %{status: status}} ->
        Logger.warning("Alpaca: HTTP #{status} for #{path}")
        {:error, "alpaca #{status}"}

      {:error, reason} ->
        Logger.error("Alpaca: request failed for #{path}: #{inspect(reason)}")
        {:error, "alpaca HTTP: #{inspect(reason)}"}
    end
  end

  defp parse_account({:ok, body}) do
    {:ok,
     %{
       equity: parse_float(body["equity"]),
       cash: parse_float(body["cash"]),
       buying_power: parse_float(body["buying_power"]),
       portfolio_value: parse_float(body["portfolio_value"]),
       day_trade_count: body["daytrade_count"] || 0,
       status: body["status"] || "unknown",
       # Margin / shortable fields exposed for the dashboard headroom
       # cards and the worker's short-selling pre-flight. multiplier=1
       # means cash account; 2/4 means margin account.
       regt_buying_power: parse_float(body["regt_buying_power"]),
       daytrading_buying_power: parse_float(body["daytrading_buying_power"]),
       non_marginable_buying_power: parse_float(body["non_marginable_buying_power"]),
       multiplier: parse_float(body["multiplier"]),
       shorting_enabled: parse_bool(body["shorting_enabled"])
     }}
  end

  defp parse_account(err), do: err

  defp parse_position(p) do
    %{
      symbol: p["symbol"],
      qty: parse_float(p["qty"]),
      side: p["side"],
      avg_entry: parse_float(p["avg_entry_price"]),
      current_price: parse_float(p["current_price"]),
      market_value: parse_float(p["market_value"]),
      unrealized_pl: parse_float(p["unrealized_pl"]),
      unrealized_plpc: parse_float(p["unrealized_plpc"])
    }
  end

  defp parse_order(o) do
    %{
      id: o["id"],
      symbol: o["symbol"],
      side: o["side"],
      qty: parse_float(o["qty"]),
      filled_qty: parse_float(o["filled_qty"]),
      filled_avg_price: parse_float(o["filled_avg_price"]),
      status: o["status"],
      submitted_at: o["submitted_at"]
    }
  end

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v / 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
end
