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

  # CoinGecko free tier: 429s arrive in clusters. Once we've been
  # told off, every additional request just adds latency and load to
  # whatever process is calling — and previously, when the call lived
  # inside `Repo.with_user`, those 8s waits each held a DB connection
  # and tripped the 15s pool checkout timeout. Cache the rate-limit
  # window in :persistent_term so all callers short-circuit during
  # the cooldown without an HTTP round-trip.
  @rate_limit_cooldown_seconds 60
  @rate_limit_key {__MODULE__, :rate_limited_until}

  # CoinGecko free tier ships ~30 req/min and the agent fleet ticks
  # every ~60s — under burst, that's enough to chase the 429 window.
  # Crypto spot doesn't need sub-second freshness for paper sizing or
  # edge scoring, so a 10s TTL collapses N concurrent ticks for the
  # same market into a single upstream call. Errors/429s are NOT
  # cached; they fall through to the existing rate-limit cooldown so
  # we don't pin stale errors.
  @cache_ttl_seconds 10

  @doc "Fetch full market data for a symbol. Returns {:ok, map} or {:error, reason}."
  def get(market) do
    cond do
      rate_limit_active?() ->
        {:error, :rate_limited}

      cached = cache_lookup(market) ->
        {:ok, cached}

      true ->
        case do_fetch(market) do
          {:ok, data} = ok ->
            cache_put(market, data)
            ok

          err ->
            err
        end
    end
  end

  defp do_fetch(market) do
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
        record_rate_limit()
        Logger.warning("PriceOracle: rate limited by CoinGecko — cooling down 60s")
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, "http_#{status}"}

      {:error, reason} ->
        Logger.error("PriceOracle: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp rate_limit_active? do
    case :persistent_term.get(@rate_limit_key, nil) do
      nil -> false
      until when is_integer(until) -> System.system_time(:second) < until
    end
  end

  defp record_rate_limit do
    until = System.system_time(:second) + @rate_limit_cooldown_seconds
    :persistent_term.put(@rate_limit_key, until)
  end

  defp cache_key(market), do: {__MODULE__, :cache, market}

  defp cache_lookup(market) do
    case :persistent_term.get(cache_key(market), nil) do
      {expires_at, data} when is_integer(expires_at) ->
        if System.system_time(:second) < expires_at, do: data, else: nil

      _ ->
        nil
    end
  end

  defp cache_put(market, data) do
    expires_at = System.system_time(:second) + @cache_ttl_seconds
    :persistent_term.put(cache_key(market), {expires_at, data})
  end

  @doc false
  def reset_rate_limit_cache do
    :persistent_term.erase(@rate_limit_key)
  end

  @doc false
  def reset_cache do
    Enum.each(Map.keys(@coin_ids), fn market ->
      :persistent_term.erase(cache_key(market))
    end)
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
