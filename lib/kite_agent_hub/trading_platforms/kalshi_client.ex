defmodule KiteAgentHub.TradingPlatforms.KalshiClient do
  @moduledoc """
  Kalshi Trading API client (RSA-PSS authenticated).

  Auth: KALSHI-ACCESS-KEY header + RSA-PSS signature.
  Demo base: https://demo-api.kalshi.co/trade-api/v2
  Live base: https://api.elections.kalshi.com/trade-api/v2

  The private key is stored as a PEM string (from Credentials.fetch_secret_with_env).
  Each request is signed with: timestamp_ms + method + path (stripped of query params).
  Host is NOT part of the signature, so the same signature works for demo and live —
  the demo and live key pairs are different so the env routing matters at the host
  level only.

  Usage:
    {:ok, {key_id, pem, env}} = Credentials.fetch_secret_with_env(org_id, :kalshi)
    {:ok, balance} = KalshiClient.balance(key_id, pem, env)
    {:ok, positions} = KalshiClient.positions(key_id, pem, env)
    {:ok, order} = KalshiClient.place_order(key_id, pem, "BTCZ-...", "yes", 5, 55, env)

  `env` is "paper" (default, demo) or "live". Unknown values fall back to demo.
  """

  @demo_host "https://demo-api.kalshi.co"
  @live_host "https://api.elections.kalshi.com"
  @api_prefix "/trade-api/v2"

  # Pick the host based on credential env. "live" → production, anything else
  # (including "paper", nil, or a typo) routes to demo for safety. Mirrors the
  # AlpacaClient.base_url/1 catch-all defense pattern from PR #79.
  defp base_host("live"), do: @live_host
  defp base_host(_), do: @demo_host

  @doc "Fetch portfolio balance — available_balance, portfolio_value."
  def balance(key_id, pem, env \\ "paper") do
    case get("/portfolio/balance", key_id, pem, env) do
      {:ok, %{"balance" => bal}} ->
        {:ok, %{available_balance: bal / 100.0, currency: "USD"}}

      {:ok, body} ->
        {:ok, %{available_balance: 0.0, currency: "USD", raw: body}}

      err ->
        err
    end
  end

  @doc """
  List Kalshi markets filtered by status. Used by the market-scan
  endpoint to surface NEW contracts above a score threshold.

  `status` default is `"open"`. `limit` 1..1000 (Kalshi caps at 1000).
  Returns raw market maps (not parsed to a fixed shape) so the scorer
  can pick whichever fields it needs without a second pass.
  """
  def list_markets(key_id, pem, opts \\ []) do
    status = Keyword.get(opts, :status, "open")
    limit = Keyword.get(opts, :limit, 200)
    env = Keyword.get(opts, :env, "paper")

    path = "/markets?status=#{status}&limit=#{limit}"

    case get(path, key_id, pem, env) do
      {:ok, %{"markets" => list}} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:ok, []}
      err -> err
    end
  end

  @doc "Fetch open positions. Returns list of position maps."
  def positions(key_id, pem, env \\ "paper") do
    case get("/portfolio/positions?limit=50", key_id, pem, env) do
      {:ok, %{"market_positions" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_position/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Place a limit order on Kalshi.

  ticker  — market ticker, e.g. "BTCZ-24DEC2031-B80000"
  side    — "yes" or "no"
  count   — number of contracts (integer)
  price   — limit price in cents (integer, 1-99)
  env     — "paper" (demo, default) or "live"

  Returns {:ok, %{id, ticker, side, count, status}} or {:error, reason}.
  """
  def place_order(key_id, pem, ticker, side, count, price, env \\ "paper") do
    body = %{
      "ticker" => ticker,
      "action" => "buy",
      "side" => side,
      "count" => count,
      "type" => "limit",
      "yes_price" => if(side == "yes", do: price, else: 100 - price),
      "no_price" => if(side == "no", do: price, else: 100 - price)
    }

    post("/portfolio/orders", body, key_id, pem, env)
    |> parse_placed_order()
  end

  @doc "Fetch recent fills (trade history). Returns list of fill maps."
  def fills(key_id, pem, limit \\ 20, env \\ "paper") do
    case get("/portfolio/fills?limit=#{limit}", key_id, pem, env) do
      {:ok, %{"fills" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_fill/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc "Fetch recent orders. Returns list of order maps."
  def orders(key_id, pem, limit \\ 20, env \\ "paper") do
    case get("/portfolio/orders?limit=#{limit}", key_id, pem, env) do
      {:ok, %{"orders" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_order/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc "Fetch settlements. Returns list of settlement maps."
  def settlements(key_id, pem, limit \\ 20, env \\ "paper") do
    case get("/portfolio/settlements?limit=#{limit}", key_id, pem, env) do
      {:ok, %{"settlements" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_settlement/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp post(path, body, key_id, pem, env) do
    ts_ms = System.os_time(:millisecond)
    full_path = @api_prefix <> path
    msg = "#{ts_ms}POST#{full_path}"

    case sign_request(msg, pem) do
      {:ok, signature_b64} ->
        headers = [
          {"KALSHI-ACCESS-KEY", key_id},
          {"KALSHI-ACCESS-SIGNATURE", signature_b64},
          {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts_ms)}
        ]

        case Req.post(base_host(env) <> full_path, json: body, headers: headers) do
          {:ok, %{status: s, body: resp_body}} when s in [200, 201] -> {:ok, resp_body}
          {:ok, %{status: 401, body: resp_body}} -> {:error, "kalshi 401: #{inspect(resp_body)}"}
          {:ok, %{status: status, body: resp_body}} -> {:error, "kalshi #{status}: #{inspect(resp_body)}"}
          {:error, reason} -> {:error, "kalshi HTTP: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "kalshi sign failed: #{inspect(reason)}"}
    end
  end

  defp parse_placed_order({:ok, %{"order" => o}}) do
    {:ok,
     %{
       id: o["order_id"],
       ticker: o["ticker"],
       side: o["side"],
       count: o["count"],
       status: o["status"]
     }}
  end

  defp parse_placed_order({:ok, _}), do: {:error, "unexpected kalshi order response shape"}
  defp parse_placed_order(err), do: err

  defp get(path, key_id, pem, env) do
    ts_ms = System.os_time(:millisecond)
    full_path = @api_prefix <> path
    clean_path = String.split(full_path, "?") |> List.first()
    msg = "#{ts_ms}GET#{clean_path}"

    case sign_request(msg, pem) do
      {:ok, signature_b64} ->
        headers = [
          {"KALSHI-ACCESS-KEY", key_id},
          {"KALSHI-ACCESS-SIGNATURE", signature_b64},
          {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts_ms)}
        ]

        case Req.get(base_host(env) <> full_path, headers: headers) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: 401, body: body}} -> {:error, "kalshi 401: #{inspect(body)}"}
          {:ok, %{status: status, body: body}} -> {:error, "kalshi #{status}: #{inspect(body)}"}
          {:error, reason} -> {:error, "kalshi HTTP: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "kalshi sign failed: #{inspect(reason)}"}
    end
  end

  defp sign_request(message, pem) do
    require Logger

    # Normalize PEM: fix escaped newlines, ensure proper line breaks
    normalized_pem =
      pem
      |> String.replace("\\n", "\n")
      |> String.replace("\r\n", "\n")
      |> String.trim()

    has_begin = String.contains?(normalized_pem, "BEGIN")
    pem_len = String.length(normalized_pem)
    line_count = normalized_pem |> String.split("\n") |> length()
    Logger.info("Kalshi: PEM diagnostics — length=#{pem_len}, lines=#{line_count}, has_BEGIN=#{has_begin}")

    try do
      entries = :public_key.pem_decode(normalized_pem)
      Logger.info("Kalshi: PEM decode returned #{length(entries)} entries")

      case entries do
        [] ->
          Logger.warning("Kalshi: PEM decode returned empty — key may be malformed")
          {:error, "PEM decode failed: no entries found"}

        [pem_entry | _] ->
          {type, _der, _cipher} = pem_entry
          Logger.info("Kalshi: PEM entry type: #{type}")

          private_key = :public_key.pem_entry_decode(pem_entry)
          Logger.info("Kalshi: private key decoded successfully")

          signature =
            :public_key.sign(
              message,
              :sha256,
              private_key,
              [{:rsa_padding, :rsa_pkcs1_pss_padding}, {:rsa_pss_saltlen, 32}]
            )

          {:ok, Base.encode64(signature)}
      end
    rescue
      e ->
        Logger.warning("Kalshi: sign_request failed at: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  defp parse_position(p) do
    %{
      market_id: p["market_id"] || p["ticker"],
      title: p["title"] || p["market_id"] || "—",
      side: p["side"],
      contracts: p["position"] || 0,
      avg_price: (p["average_price"] || 0) / 100.0,
      current_price: (p["last_price"] || 0) / 100.0,
      value: ((p["position"] || 0) * (p["last_price"] || 0)) / 100.0,
      settled: p["settled"] || false
    }
  end

  defp parse_fill(f) do
    %{
      trade_id: f["trade_id"],
      ticker: f["ticker"],
      side: f["side"],
      action: f["action"],
      count: f["count"] || 0,
      price: fill_price_cents(f) / 100.0,
      created_time: f["created_time"]
    }
  end

  # Kalshi fill responses include BOTH yes_price and no_price in cents.
  # For a YES fill the trade price is yes_price; for a NO fill it's
  # no_price. The old `yes_price || no_price` short-circuit was buggy:
  # in Elixir `0 || x` returns 0 (0 is truthy), so NO fills with a
  # valid no_price would still pick yes_price=0 and every NO trade
  # landed on the chart at $0 — producing a flat sparkline.
  defp fill_price_cents(%{"side" => "no", "no_price" => p}) when is_number(p), do: p
  defp fill_price_cents(%{"side" => "yes", "yes_price" => p}) when is_number(p), do: p
  defp fill_price_cents(%{"no_price" => p}) when is_number(p) and p > 0, do: p
  defp fill_price_cents(%{"yes_price" => p}) when is_number(p) and p > 0, do: p
  defp fill_price_cents(_), do: 0

  defp parse_order(o) do
    %{
      order_id: o["order_id"],
      ticker: o["ticker"],
      side: o["side"],
      action: o["action"],
      type: o["type"],
      count: o["remaining_count"] || o["count"] || 0,
      price: fill_price_cents(o) / 100.0,
      status: o["status"],
      created_time: o["created_time"]
    }
  end

  defp parse_settlement(s) do
    %{
      ticker: s["ticker"],
      market_result: s["market_result"],
      revenue: (s["revenue"] || 0) / 100.0,
      settled_time: s["settled_time"]
    }
  end
end
