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
  Fetch portfolio equity history for sparkline chart.
  Returns {:ok, [%{t: unix_ts, v: equity_float}]} or {:error, reason}.
  """
  def portfolio_history(key_id, secret, period \\ "1M", timeframe \\ "1D", env \\ "paper") do
    case get("/v2/account/portfolio/history?period=#{period}&timeframe=#{timeframe}", key_id, secret, env) do
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
    case get("/v2/orders?status=filled&limit=#{limit}&direction=desc", key_id, secret, env) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &parse_order/1)}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc """
  Place a market order on Alpaca paper trading.

  symbol  — e.g. "ETHUSD", "BTCUSD", "SPY"
  qty     — number of shares/units (string or float)
  side    — "buy" or "sell"

  Returns {:ok, %{id, symbol, side, qty, status}} or {:error, reason}.
  """
  def place_order(key_id, secret, symbol, qty, side \\ "buy") do
    body = %{
      "symbol" => symbol,
      "qty" => to_string(qty),
      "side" => side,
      "type" => "market",
      "time_in_force" => "day"
    }

    post("/v2/orders", body, key_id, secret)
    |> parse_placed_order()
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp post(path, body, key_id, secret, env \\ "paper") do
    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.post(base_url(env) <> path, json: body, headers: headers) do
      {:ok, %{status: s, body: resp_body}} when s in [200, 201] -> {:ok, resp_body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: resp_body}} -> {:error, "alpaca #{status}: #{inspect(resp_body)}"}
      {:error, reason} -> {:error, "alpaca HTTP: #{inspect(reason)}"}
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

  defp get(path, key_id, secret, env \\ "paper") do
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
       status: body["status"] || "unknown"
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
