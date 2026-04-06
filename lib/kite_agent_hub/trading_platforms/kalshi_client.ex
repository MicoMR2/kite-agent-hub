defmodule KiteAgentHub.TradingPlatforms.KalshiClient do
  @moduledoc """
  Kalshi Demo Trading API client (RSA-PSS authenticated).

  Auth: KALSHI-ACCESS-KEY header + RSA-PSS signature.
  Demo base: https://demo-api.kalshi.co/trade-api/v2

  The private key is stored as a PEM string (from Credentials.fetch_secret).
  Each request is signed with: timestamp_ms + method + path (stripped of query params).

  Usage:
    {:ok, {key_id, pem}} = Credentials.fetch_secret(org_id, :kalshi)
    {:ok, balance} = KalshiClient.balance(key_id, pem)
    {:ok, positions} = KalshiClient.positions(key_id, pem)
    {:ok, order} = KalshiClient.place_order(key_id, pem, "BTCZ-...", "yes", 5, 55)
  """

  @demo_host "https://demo-api.kalshi.co"
  @api_prefix "/trade-api/v2"

  @doc "Fetch portfolio balance — available_balance, portfolio_value."
  def balance(key_id, pem) do
    case get("/portfolio/balance", key_id, pem) do
      {:ok, %{"balance" => bal}} ->
        {:ok, %{available_balance: bal / 100.0, currency: "USD"}}

      {:ok, body} ->
        {:ok, %{available_balance: 0.0, currency: "USD", raw: body}}

      err ->
        err
    end
  end

  @doc "Fetch open positions. Returns list of position maps."
  def positions(key_id, pem) do
    case get("/portfolio/positions?limit=50", key_id, pem) do
      {:ok, %{"market_positions" => list}} when is_list(list) ->
        {:ok, Enum.map(list, &parse_position/1)}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Place a limit order on Kalshi demo.

  ticker  — market ticker, e.g. "BTCZ-24DEC2031-B80000"
  side    — "yes" or "no"
  count   — number of contracts (integer)
  price   — limit price in cents (integer, 1-99)

  Returns {:ok, %{id, ticker, side, count, status}} or {:error, reason}.
  """
  def place_order(key_id, pem, ticker, side, count, price) do
    body = %{
      "ticker" => ticker,
      "action" => "buy",
      "side" => side,
      "count" => count,
      "type" => "limit",
      "yes_price" => if(side == "yes", do: price, else: 100 - price),
      "no_price" => if(side == "no", do: price, else: 100 - price)
    }

    post("/portfolio/orders", body, key_id, pem)
    |> parse_placed_order()
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp post(path, body, key_id, pem) do
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

        case Req.post(@demo_host <> full_path, json: body, headers: headers) do
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

  defp get(path, key_id, pem) do
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

        case Req.get(@demo_host <> full_path, headers: headers) do
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
end
