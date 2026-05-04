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
  Fetch a single market's full detail by ticker. Returns lifecycle
  status, top-of-book yes/no bid/ask in cents, last_price, close_time,
  and title — everything the dashboard needs to render a position row
  with live context.

  Returns `{:ok, parsed_market}` or `{:error, reason}`.
  """
  def market(key_id, pem, ticker, env \\ "paper") do
    case get("/markets/#{ticker}", key_id, pem, env) do
      {:ok, %{"market" => m}} when is_map(m) -> {:ok, parse_market(m)}
      {:ok, _} -> {:error, "kalshi market response missing market key"}
      err -> err
    end
  end

  @doc """
  Batch-fetch multiple markets by ticker in one round trip. Used to
  enrich the positions table with lifecycle state + live spread
  without N+1 calls.

  Returns `{:ok, %{ticker => parsed_market}}`. Tickers absent from the
  response are simply not in the map; callers handle the miss.
  """
  def markets_by_tickers(key_id, pem, tickers, env \\ "paper") when is_list(tickers) do
    case tickers do
      [] ->
        {:ok, %{}}

      _ ->
        joined = tickers |> Enum.uniq() |> Enum.join(",")
        path = "/markets?tickers=#{URI.encode(joined)}&limit=#{length(tickers) + 50}"

        case get(path, key_id, pem, env) do
          {:ok, %{"markets" => list}} when is_list(list) ->
            map = Map.new(list, fn m -> {m["ticker"], parse_market(m)} end)
            {:ok, map}

          {:ok, _} ->
            {:ok, %{}}

          err ->
            err
        end
    end
  end

  @doc """
  Fetch a market's orderbook. Kalshi returns ascending arrays of
  [price_cents, size] pairs per side; the strongest bid is the last
  element. Returns `{:ok, %{yes_bid_cents, no_bid_cents, yes_ask_cents,
  no_ask_cents, yes_levels, no_levels, spread_cents}}` where
  best yes ask = 100 - best no bid (reciprocal binary).
  """
  def orderbook(key_id, pem, ticker, env \\ "paper") do
    case get("/markets/#{ticker}/orderbook", key_id, pem, env) do
      {:ok, %{"orderbook" => ob}} when is_map(ob) -> {:ok, parse_orderbook(ob)}
      {:ok, _} -> {:error, "kalshi orderbook response missing orderbook key"}
      err -> err
    end
  end

  @doc """
  Convenience: takes a list of `parse_position/1` maps and merges in
  market lifecycle state + top-of-book bid/ask via a single
  `markets_by_tickers` round trip. Dashboard-friendly. Positions whose
  market lookup fails fall through with the original fields.
  """
  def enrich_positions(key_id, pem, positions, env \\ "paper") when is_list(positions) do
    tickers = Enum.map(positions, & &1.market_id) |> Enum.reject(&is_nil/1)

    case markets_by_tickers(key_id, pem, tickers, env) do
      {:ok, by_ticker} ->
        enriched =
          Enum.map(positions, fn pos ->
            case Map.get(by_ticker, pos.market_id) do
              nil -> pos
              market -> Map.merge(pos, market_overlay(pos, market))
            end
          end)

        {:ok, enriched}

      {:error, _} ->
        # Lookup failed; return positions unenriched rather than blocking the tab.
        {:ok, positions}
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
  def place_order(key_id, pem, ticker, side, count, price, env \\ "paper", opts \\ []) do
    with {:ok, body} <- order_body(ticker, side, count, price, opts) do
      post("/portfolio/orders", body, key_id, pem, env)
      |> parse_placed_order()
    end
  end

  @doc false
  def order_body(ticker, side, count, price, opts \\ []) do
    opts = normalize_opts(opts)
    action = normalize_action(opts["action"] || "buy")

    with {:ok, price_cents} <- normalize_price(price) do
      body =
        %{
          "ticker" => ticker,
          "action" => action,
          "side" => side,
          "count" => count,
          "type" => normalize_order_type(opts["order_type"] || opts["type"] || "limit")
        }
        |> put_kalshi_prices(side, price_cents, opts)
        |> put_optional("client_order_id", opts["client_order_id"])
        |> put_optional("count_fp", opts["count_fp"])
        |> put_optional("expiration_ts", parse_int(opts["expiration_ts"]))
        |> put_optional("time_in_force", normalize_time_in_force(opts["time_in_force"]))
        |> put_optional("buy_max_cost", parse_int(opts["buy_max_cost"]))
        |> put_optional("post_only", parse_bool(opts["post_only"]))
        |> put_optional("reduce_only", reduce_only_value(action, opts["reduce_only"]))
        |> put_optional("self_trade_prevention_type", opts["self_trade_prevention_type"])
        |> put_optional("order_group_id", opts["order_group_id"])
        |> put_optional("cancel_order_on_pause", parse_bool(opts["cancel_order_on_pause"]))
        |> put_optional("subaccount", parse_int(opts["subaccount"]))

      {:ok, body}
    end
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

  @doc """
  Fetch resting (pending) limit orders — orders sitting in the book
  awaiting a counterparty fill. Filters server-side by `status=resting`
  so the response only contains open, cancellable orders.

  Returns `{:ok, [order_map]}` where each order includes an `:order_id`
  field usable with `cancel_order/4` or `amend_order/6`.
  """
  def list_pending_orders(key_id, pem, env \\ "paper") do
    case get("/portfolio/orders?status=resting&limit=200", key_id, pem, env) do
      {:ok, %{"orders" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_order/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Fetch a single order by its Kalshi order ID.

  Returns `{:ok, order_map}` or `{:error, reason}`. Useful for polling
  the fill status of a specific resting order without fetching the full
  pending list.
  """
  def get_order(key_id, pem, order_id, env \\ "paper") do
    case get("/portfolio/orders/#{order_id}", key_id, pem, env) do
      {:ok, %{"order" => o}} when is_map(o) -> {:ok, parse_order(o)}
      {:ok, _} -> {:error, "kalshi get_order: unexpected response shape"}
      err -> err
    end
  end

  @doc """
  Cancel a single resting order by its Kalshi order ID.

  `DELETE /portfolio/orders/{order_id}` returns the cancelled order.
  Kalshi does NOT use HTTP 204 here — it returns 200 with the order body.

  Returns:
  - `{:ok, :cancelled}` on success
  - `{:ok, :already_terminal}` when the order is filled/cancelled/expired
    (Kalshi returns 400 with `code: "order_not_found"` or similar)
  - `{:error, reason}` on auth or transport failure
  """
  def cancel_order(key_id, pem, order_id, env \\ "paper") do
    delete("/portfolio/orders/#{order_id}", key_id, pem, env)
  end

  @doc """
  Amend a resting order's price and/or count in place.

  Kalshi supports `PATCH /portfolio/orders/{order_id}` to atomically
  adjust a limit order without cancelling + re-entering. If only one
  of `price_cents` or `count` needs to change, pass `nil` for the other.

  Returns `{:ok, order_map}` or `{:error, reason}`.
  """
  def amend_order(key_id, pem, order_id, opts \\ [], env \\ "paper") do
    body =
      %{}
      |> put_optional("count", opts[:count])
      |> put_optional("yes_price", opts[:yes_price_cents])
      |> put_optional("no_price", opts[:no_price_cents])

    patch("/portfolio/orders/#{order_id}", body, key_id, pem, env)
    |> parse_placed_order()
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

  # Kalshi's CreateOrder endpoint requires *exactly one* of yes_price,
  # no_price, yes_price_dollars, or no_price_dollars per request — sending
  # the cross-side derivation (both yes_price and no_price) bounces with
  # `invalid_order`. We always emit the cents-form field that matches
  # the side being traded; opts can override the value but never the field.
  defp put_kalshi_prices(body, side, price_cents, opts) do
    case normalize_kalshi_side(side) do
      "no" ->
        Map.put(body, "no_price", normalize_price_value(opts["no_price"]) || price_cents)

      _ ->
        Map.put(body, "yes_price", normalize_price_value(opts["yes_price"]) || price_cents)
    end
  end

  defp normalize_kalshi_side(side) when is_binary(side),
    do: side |> String.trim() |> String.downcase()

  defp normalize_kalshi_side(_), do: "yes"

  defp normalize_action("sell"), do: "sell"
  defp normalize_action(_), do: "buy"

  defp normalize_order_type(type) when is_binary(type),
    do: type |> String.trim() |> String.downcase()

  defp normalize_order_type(type), do: type |> to_string() |> String.downcase()

  defp normalize_time_in_force(nil), do: nil

  defp normalize_time_in_force(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_time_in_force(value), do: to_string(value)

  defp reduce_only_value("sell", nil), do: true
  defp reduce_only_value(_action, value), do: parse_bool(value)

  defp normalize_price(price) do
    case normalize_price_value(price) do
      cents when is_integer(cents) and cents in 1..99 -> {:ok, cents}
      _ -> {:error, "kalshi price must be between 1 and 99 cents"}
    end
  end

  defp normalize_price_value(nil), do: nil
  defp normalize_price_value(price) when is_integer(price), do: price

  defp normalize_price_value(price) when is_float(price) and price > 0 and price <= 1,
    do: round(price * 100)

  defp normalize_price_value(price) when is_float(price), do: round(price)

  defp normalize_price_value(price) when is_binary(price) do
    price = String.trim(price)

    cond do
      price == "" ->
        nil

      String.contains?(price, ".") ->
        case Float.parse(price) do
          {value, ""} when value > 0 and value <= 1 -> round(value * 100)
          {value, ""} -> round(value)
          _ -> nil
        end

      true ->
        case Integer.parse(price) do
          {value, ""} -> value
          _ -> nil
        end
    end
  end

  defp normalize_price_value(_price), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_int(_value), do: nil

  defp parse_bool(nil), do: nil
  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool("true"), do: true
  defp parse_bool("false"), do: false
  defp parse_bool(value), do: value

  defp normalize_opts(opts) when is_map(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp normalize_opts(opts) when is_list(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp normalize_opts(_opts), do: %{}

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

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
          {:ok, %{status: s, body: resp_body}} when s in [200, 201] ->
            {:ok, resp_body}

          {:ok, %{status: 401, body: resp_body}} ->
            {:error, "kalshi 401: #{inspect(resp_body)}"}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, "kalshi #{status}: #{inspect(resp_body)}"}

          {:error, reason} ->
            {:error, "kalshi HTTP: #{inspect(reason)}"}
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

  # PATCH helper for amend_order. Mirrors post/5 but uses Req.patch.
  defp patch(path, body, key_id, pem, env) do
    ts_ms = System.os_time(:millisecond)
    full_path = @api_prefix <> path
    msg = "#{ts_ms}PATCH#{full_path}"

    case sign_request(msg, pem) do
      {:ok, signature_b64} ->
        headers = [
          {"KALSHI-ACCESS-KEY", key_id},
          {"KALSHI-ACCESS-SIGNATURE", signature_b64},
          {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts_ms)}
        ]

        case Req.patch(base_host(env) <> full_path, json: body, headers: headers) do
          {:ok, %{status: s, body: resp_body}} when s in [200, 201] ->
            {:ok, resp_body}

          {:ok, %{status: 401, body: resp_body}} ->
            {:error, "kalshi 401: #{inspect(resp_body)}"}

          {:ok, %{status: status, body: resp_body}} ->
            {:error, "kalshi #{status}: #{inspect(resp_body)}"}

          {:error, reason} ->
            {:error, "kalshi HTTP: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "kalshi sign failed: #{inspect(reason)}"}
    end
  end

  # DELETE helper for cancel_order.
  defp delete(path, key_id, pem, env) do
    require Logger

    ts_ms = System.os_time(:millisecond)
    full_path = @api_prefix <> path
    msg = "#{ts_ms}DELETE#{full_path}"

    case sign_request(msg, pem) do
      {:ok, signature_b64} ->
        headers = [
          {"KALSHI-ACCESS-KEY", key_id},
          {"KALSHI-ACCESS-SIGNATURE", signature_b64},
          {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts_ms)}
        ]

        url = base_host(env) <> full_path

        case Req.delete(url, headers: headers, retry: false) do
          {:ok, %{status: s}} when s in [200, 204] ->
            {:ok, :cancelled}

          {:ok, %{status: 400, body: body}} ->
            # Kalshi returns 400 with a code string when the order is
            # not in a cancellable state (already filled / expired).
            # Treat as idempotent so the UI can safely retry.
            Logger.info("Kalshi DELETE #{path} — 400 (not cancellable): #{inspect(body)}")
            {:ok, :already_terminal}

          {:ok, %{status: 401, body: body}} ->
            {:error, "kalshi 401: #{inspect(body)}"}

          {:ok, %{status: status, body: body}} ->
            {:error, "kalshi #{status}: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "kalshi HTTP: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "kalshi sign failed: #{inspect(reason)}"}
    end
  end

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

    Logger.info(
      "Kalshi: PEM diagnostics — length=#{pem_len}, lines=#{line_count}, has_BEGIN=#{has_begin}"
    )

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
      value: (p["position"] || 0) * (p["last_price"] || 0) / 100.0,
      settled: p["settled"] || false,
      # Lifecycle / live-quote fields are nil until enriched via
      # `enrich_positions/4`. Dashboard renders them when present and
      # falls back to the cached current_price otherwise.
      status: nil,
      close_time: nil,
      live_yes_bid_cents: nil,
      live_yes_ask_cents: nil,
      live_no_bid_cents: nil,
      live_no_ask_cents: nil
    }
  end

  defp parse_market(m) do
    %{
      ticker: m["ticker"],
      title: m["title"] || m["subtitle"] || m["ticker"],
      status: m["status"],
      close_time: m["close_time"],
      open_time: m["open_time"],
      last_price_cents: m["last_price"],
      yes_bid_cents: m["yes_bid"],
      yes_ask_cents: m["yes_ask"],
      no_bid_cents: m["no_bid"],
      no_ask_cents: m["no_ask"],
      volume: m["volume"],
      volume_24h: m["volume_24h"]
    }
  end

  # Pull the fields a position row actually displays (state + the live
  # bid/ask for the side the user holds) out of the full parsed market.
  # Keeps the caller's merge surface narrow + intentional.
  defp market_overlay(pos, market) do
    %{
      status: market.status,
      close_time: market.close_time,
      live_yes_bid_cents: market.yes_bid_cents,
      live_yes_ask_cents: market.yes_ask_cents,
      live_no_bid_cents: market.no_bid_cents,
      live_no_ask_cents: market.no_ask_cents,
      # Refresh current_price from live last when available — the cached
      # value on the position can be minutes stale.
      current_price:
        case market.last_price_cents do
          n when is_number(n) -> n / 100.0
          _ -> pos.current_price
        end
    }
  end

  defp parse_orderbook(ob) do
    yes_levels = level_pairs(ob["yes"])
    no_levels = level_pairs(ob["no"])

    yes_bid = top_level(yes_levels)
    no_bid = top_level(no_levels)

    yes_ask = if no_bid, do: 100 - no_bid, else: nil
    no_ask = if yes_bid, do: 100 - yes_bid, else: nil

    spread_cents =
      if is_number(yes_bid) and is_number(yes_ask) and yes_ask >= yes_bid,
        do: yes_ask - yes_bid,
        else: nil

    %{
      yes_bid_cents: yes_bid,
      no_bid_cents: no_bid,
      yes_ask_cents: yes_ask,
      no_ask_cents: no_ask,
      spread_cents: spread_cents,
      yes_levels: yes_levels,
      no_levels: no_levels
    }
  end

  # Kalshi orderbook arrays are [[price_cents, size], ...] sorted
  # ascending by price. Top of book (best bid) is the last element.
  defp level_pairs(nil), do: []
  defp level_pairs(list) when is_list(list), do: list
  defp level_pairs(_), do: []

  defp top_level([_ | _] = list) do
    case List.last(list) do
      [price, _size] when is_integer(price) -> price
      _ -> nil
    end
  end

  defp top_level(_), do: nil

  defp parse_fill(f) do
    %{
      trade_id: f["trade_id"],
      ticker: f["ticker"],
      side: f["side"],
      action: f["action"],
      count: f["count"] || 0,
      price: fill_price_cents(f) / 100.0,
      # Kalshi fee model: trade_fee + rounding_fee - rebate (per
      # /getting_started/fee_rounding). The aggregated cost lands in
      # the `fees` field on the fill response in cents — capture it
      # so settlement P&L can subtract real net fees instead of pretending
      # they're zero.
      fees_cents: f["fees"] || f["fee"] || 0,
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
      # Per Kalshi: settlement payouts are typically fee-free for binary
      # outcomes, but expose a fee field anyway in case scalar markets
      # ship with one. Caller can decide how to roll into net P&L.
      fees: (s["fees"] || 0) / 100.0,
      settled_time: s["settled_time"]
    }
  end
end
