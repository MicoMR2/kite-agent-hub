defmodule KiteAgentHubWeb.API.ScoreController do
  @moduledoc """
  REST endpoint for external LLMs to score a hypothetical NEW entry on
  any ticker. Where `/api/v1/edge-scores` only ranks positions the agent
  already holds, this endpoint answers "should I open a position in
  TICKER right now?" — driven by recent OHLCV bars from the Alpaca
  market data API and the QRB-style entry scoring in
  `KiteAgentHub.Kite.TickerScorer`.

  Auth: `Authorization: Bearer <agent_api_token>` — same scheme as
  `/api/v1/trades`, `/api/v1/chat`, and `/api/v1/edge-scores`. The
  ticker is read from the query string. Alpaca credentials are pulled
  from the encrypted DB column scoped to the agent's organization —
  the agent never holds raw Alpaca keys.

  Example:
    GET /api/v1/score?ticker=AAPL

  Response:
    {
      "ok": true,
      "ticker": "AAPL",
      "score": 78,
      "signal": "buy",
      "last_price": 187.42,
      "sma_20": 182.10,
      "change_5d_pct": 3.15,
      "change_20d_pct": 8.42,
      "avg_volume": 53412000,
      "breakdown": {
        "trend": 30,
        "momentum": 20,
        "volatility": 18,
        "liquidity": 20
      }
    }
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.Kite.TickerScorer
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  def show(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, ticker} <- fetch_ticker(params),
         {:ok, {key_id, secret, _env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca),
         {:ok, bars} <- AlpacaClient.bars(key_id, secret, ticker) do
      case TickerScorer.score_ticker(ticker, bars) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{ok: false, error: "no bars returned for #{ticker}"})

        score ->
          conn
          |> json(%{
            ok: true,
            ticker: score.ticker,
            score: score.score,
            signal: score.signal,
            last_price: score.last_price,
            sma_20: score.sma_20,
            change_5d_pct: score.change_5d_pct,
            change_20d_pct: score.change_20d_pct,
            avg_volume: score.avg_volume,
            breakdown: score.breakdown
          })
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :missing_ticker} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "ticker query param is required"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured for this org"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "scoring failed: #{inspect(reason)}"})
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Trading.get_agent_by_token(token) do
          nil -> {:error, :unauthorized}
          agent -> {:ok, agent}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # Tickers are uppercase letters/digits only, max 8 chars — defends
  # against URL-injection by refusing anything that doesn't look like a
  # real symbol before forwarding it to the Alpaca data API.
  defp fetch_ticker(%{"ticker" => raw}) when is_binary(raw) do
    candidate = raw |> String.trim() |> String.upcase()

    if Regex.match?(~r/\A[A-Z0-9]{1,8}\z/, candidate) do
      {:ok, candidate}
    else
      {:error, :missing_ticker}
    end
  end

  defp fetch_ticker(_), do: {:error, :missing_ticker}
end
