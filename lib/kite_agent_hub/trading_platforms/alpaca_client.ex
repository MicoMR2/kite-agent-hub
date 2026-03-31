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

  @doc "Fetch account summary — equity, cash, buying_power, portfolio_value."
  def account(key_id, secret) do
    get("/v2/account", key_id, secret)
    |> parse_account()
  end

  @doc "Fetch open positions. Returns list of position maps."
  def positions(key_id, secret) do
    case get("/v2/positions", key_id, secret) do
      {:ok, list} when is_list(list) -> {:ok, Enum.map(list, &parse_position/1)}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc """
  Fetch portfolio equity history for sparkline chart.
  Returns {:ok, [%{t: unix_ts, v: equity_float}]} or {:error, reason}.
  """
  def portfolio_history(key_id, secret, period \\ "1M", timeframe \\ "1D") do
    case get("/v2/portfolio/history?period=#{period}&timeframe=#{timeframe}", key_id, secret) do
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

  # ── Private ───────────────────────────────────────────────────────────────────

  defp get(path, key_id, secret) do
    headers = [
      {"APCA-API-KEY-ID", key_id},
      {"APCA-API-SECRET-KEY", secret}
    ]

    case Req.get(@paper_base <> path, headers: headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: body}} -> {:error, "alpaca #{status}: #{inspect(body)}"}
      {:error, reason} -> {:error, "alpaca HTTP: #{inspect(reason)}"}
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
