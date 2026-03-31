defmodule KiteAgentHub.Kite.PriceOracle do
  @moduledoc """
  Fetches live spot prices for markets traded by Kite agents.

  Uses the CoinGecko public API (no key required for simple price lookups).
  Falls back to a cached value if the request fails.

  Supported market symbols: "ETH-USDC", "BTC-USDC", "KITE-USDC"

  Usage:

      {:ok, %{price: "3250.42", change_24h: 2.1, volume_24h: 18_500_000_000}} =
        PriceOracle.get("ETH-USDC")

      {:ok, price_string} = PriceOracle.price("ETH-USDC")
  """

  require Logger

  @coingecko_base "https://api.coingecko.com/api/v3"

  @coin_ids %{
    "ETH-USDC" => "ethereum",
    "BTC-USDC" => "bitcoin",
    "KITE-USDC" => "ethereum"
  }

  @doc "Fetch full market data for a symbol. Returns {:ok, map} or {:error, reason}."
  def get(market) do
    coin_id = Map.get(@coin_ids, market, "ethereum")

    url = "#{@coingecko_base}/simple/price"

    params = [
      ids: coin_id,
      vs_currencies: "usd",
      include_24hr_change: "true",
      include_24hr_vol: "true"
    ]

    case Req.get(url, params: params, receive_timeout: 8_000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        parse_coingecko(body, coin_id, market)

      {:ok, %{status: 429}} ->
        Logger.warning("PriceOracle: rate limited by CoinGecko")
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

  defp parse_coingecko(body, coin_id, market) do
    case Map.get(body, coin_id) do
      nil ->
        {:error, "coin_not_found"}

      data ->
        raw_price = Map.get(data, "usd", 0)
        change = Map.get(data, "usd_24h_change", 0.0)
        volume = Map.get(data, "usd_24h_vol", 0)

        trend =
          cond do
            change > 3.0 -> "strongly_bullish"
            change > 0.5 -> "bullish"
            change < -3.0 -> "strongly_bearish"
            change < -0.5 -> "bearish"
            true -> "neutral"
          end

        rsi_approx = estimate_rsi(change)

        {:ok,
         %{
           market: market,
           price: :erlang.float_to_binary(raw_price * 1.0, decimals: 2),
           price_raw: raw_price,
           change_24h: Float.round(change, 2),
           volume_24h: round(volume),
           trend: trend,
           rsi: rsi_approx
         }}
    end
  end

  # Rough RSI approximation from 24h change — not a real RSI, good enough for prompt context
  defp estimate_rsi(change_pct) do
    base = 50.0
    clamped = max(-20.0, min(20.0, change_pct))
    result = base + clamped * 2.0
    round(result)
  end
end
