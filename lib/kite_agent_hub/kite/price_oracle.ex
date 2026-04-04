defmodule KiteAgentHub.Kite.PriceOracle do
  @moduledoc """
  Fetches live spot prices for markets traded by Kite agents.

  Primary: CoinCap.io (free, no key, generous rate limits)
  No fallback needed — CoinCap has no significant rate limiting.

  Supported market symbols: "ETH-USDC", "BTC-USDC", "SOL-USDC"
  """

  require Logger

  @coincap_base "https://api.coincap.io/v2"

  @asset_ids %{
    "ETH-USDC" => "ethereum",
    "BTC-USDC" => "bitcoin",
    "SOL-USDC" => "solana",
    "KITE-USDC" => "ethereum"
  }

  @doc "Fetch full market data for a symbol. Returns {:ok, map} or {:error, reason}."
  def get(market) do
    asset_id = Map.get(@asset_ids, market, "ethereum")

    url = "#{@coincap_base}/assets/#{asset_id}"

    case Req.get(url, receive_timeout: 8_000, retry: false) do
      {:ok, %{status: 200, body: %{"data" => data}}} ->
        parse_coincap(data, market)

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"data" => data}} -> parse_coincap(data, market)
          _ -> {:error, "parse_error"}
        end

      {:ok, %{status: 429}} ->
        Logger.warning("PriceOracle: rate limited by CoinCap")
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, "http_#{status}"}

      {:error, reason} ->
        Logger.error("PriceOracle: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Fetch just the price string for a symbol. Returns {:ok, string} or {:error, reason}."
  def price(market) do
    case get(market) do
      {:ok, %{price: p}} -> {:ok, p}
      err -> err
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp parse_coincap(data, market) do
    raw_price = parse_num(data["priceUsd"], 0.0)
    change_24h = parse_num(data["changePercent24Hr"], 0.0)
    volume = parse_num(data["volumeUsd24Hr"], 0.0)

    trend =
      cond do
        change_24h > 3.0 -> "strongly_bullish"
        change_24h > 0.5 -> "bullish"
        change_24h < -3.0 -> "strongly_bearish"
        change_24h < -0.5 -> "bearish"
        true -> "neutral"
      end

    rsi_approx = estimate_rsi(change_24h)

    {:ok,
     %{
       market: market,
       price: :erlang.float_to_binary(raw_price, decimals: 2),
       price_raw: raw_price,
       change_24h: Float.round(change_24h, 2),
       volume_24h: round(volume),
       trend: trend,
       rsi: rsi_approx
     }}
  end

  defp parse_num(nil, default), do: default
  defp parse_num(val, _default) when is_float(val), do: val
  defp parse_num(val, _default) when is_integer(val), do: val / 1.0

  defp parse_num(val, default) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> default
    end
  end

  defp parse_num(_, default), do: default

  # Rough RSI approximation from 24h change
  defp estimate_rsi(change_pct) do
    base = 50.0
    clamped = max(-20.0, min(20.0, change_pct))
    result = base + clamped * 2.0
    round(result)
  end
end
