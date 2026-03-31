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
  """

  @demo_base "https://demo-api.kalshi.co/trade-api/v2"

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

  # ── Private ───────────────────────────────────────────────────────────────────

  defp get(path, key_id, pem) do
    ts_ms = System.os_time(:millisecond)
    clean_path = String.split(path, "?") |> List.first()
    msg = "#{ts_ms}GET#{clean_path}"

    case sign_request(msg, pem) do
      {:ok, signature_b64} ->
        headers = [
          {"KALSHI-ACCESS-KEY", key_id},
          {"KALSHI-ACCESS-SIGNATURE", signature_b64},
          {"KALSHI-ACCESS-TIMESTAMP", Integer.to_string(ts_ms)}
        ]

        case Req.get(@demo_base <> path, headers: headers) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: 401}} -> {:error, :unauthorized}
          {:ok, %{status: status, body: body}} -> {:error, "kalshi #{status}: #{inspect(body)}"}
          {:error, reason} -> {:error, "kalshi HTTP: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "kalshi sign failed: #{inspect(reason)}"}
    end
  end

  defp sign_request(message, pem) do
    try do
      [pem_entry] = :public_key.pem_decode(pem)
      private_key = :public_key.pem_entry_decode(pem_entry)

      signature =
        :public_key.sign(
          message,
          :sha256,
          private_key,
          [{:rsa_padding, :rsa_pkcs1_pss_padding}, {:rsa_pss_saltlen, :digest}]
        )

      {:ok, Base.encode64(signature)}
    rescue
      e -> {:error, Exception.message(e)}
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
