defmodule KiteAgentHub.Kite.PriceOracle do
  @moduledoc """
  Fetches live spot prices for markets traded by Kite agents.

  Primary: CoinGecko free tier (api.coingecko.com/api/v3) — no auth,
  ~30 calls/min unauthenticated, stable URL since 2014.

  Previously used api.coincap.io/v2 which CoinCap rebranded out of
  existence — the old hostname returns nxdomain on Fly's resolver and
  every PriceOracle.get/1 call was failing. Swapped to CoinGecko for
  the same set of native tokens (ETH/BTC/SOL).

  Supported market symbols: "ETH-USDC", "BTC-USDC", "SOL-USDC", "KITE-USDC"
  """

  require Logger

  @coingecko_base "https://api.coingecko.com/api/v3"

  # CoinGecko coin ids — different naming than CoinCap. KITE-USDC has no
  # real CoinGecko listing yet so we proxy it to ethereum like before.
  @coin_ids %{
    "ETH-USDC" => "ethereum",
    "BTC-USDC" => "bitcoin",
    "SOL-USDC" => "solana",
    "KITE-USDC" => "ethereum"
  }

  @doc "Fetch full market data for a symbol. Returns {:ok, map} or {:error, reason}."
  def get(market) do
    coin_id = Map.get(@coin_ids, market, "ethereum")

    url =
      "#{@coingecko_base}/simple/price?ids=#{coin_id}&vs_currencies=usd&include_24hr_change=true&include_24hr_vol=true"

    case Req.get(url, receive_timeout: 8_000, retry: false) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        parse_coingecko(body, coin_id, market)

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> parse_coingecko(decoded, coin_id, market)
          _ -> {:error, "parse_error"}
        end

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

  # CoinGecko response shape:
  #   %{
  #     "bitcoin" => %{
  #       "usd" => 67234.12,
  #       "usd_24h_change" => 1.234,
  #       "usd_24h_vol" => 28435000000.0
  #     }
  #   }
  defp parse_coingecko(body, coin_id, market) do
    case Map.get(body, coin_id) do
      nil ->
        {:error, "no_data_for_#{coin_id}"}

      data when is_map(data) ->
        raw_price = parse_num(data["usd"], 0.0)
        change_24h = parse_num(data["usd_24h_change"], 0.0)
        volume = parse_num(data["usd_24h_vol"], 0.0)

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
