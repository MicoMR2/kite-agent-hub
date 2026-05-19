defmodule KiteAgentHubWeb.API.KalshiEdgeScoresController do
  @moduledoc """
  REST endpoint for the new Phase 2 Kalshi edge scores (PR-K1).
  Read-only, signal-only — no auto-trade path attached. CyberSec
  10749 standing condition holds: scores recommend, the existing
  PaperExecutionWorker preflight + DrawdownGate + per-trade cap
  remain the only path to a broker POST.

  Distinct from `/api/v1/edge-scores`'s `kalshi_scores` field,
  which scores OPEN POSITIONS on entry-quality / momentum /
  risk-reward / liquidity. This endpoint scores the MARKETS the
  agent has positions in on the combined PR-K1 + PR-K2 signals:

  * Signal 1 — time-decay / closeout edge (50 pts)
  * Signal 2 — order-book imbalance × volume weight (50 pts)

  Score = sum, clamped 0..100. Recommendation thresholds same as
  K1 (≥75 :strong, ≥50 :moderate, else :pass).

  Auth: same `Authorization: Bearer <agent_api_token>` scheme.
  """

  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Credentials
  alias KiteAgentHub.Kite.KalshiEdgeScorer
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  def index(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      now = DateTime.utc_now()
      scores = compute_scores(agent.organization_id, now)

      conn
      |> json(%{
        ok: true,
        timestamp: DateTime.to_iso8601(now),
        kalshi_edge_scores: Enum.map(scores, &serialize_score/1)
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  defp compute_scores(org_id, now) do
    with {:ok, {key_id, pem, env}} <- Credentials.fetch_secret_with_env(org_id, :kalshi),
         {:ok, positions} <- KalshiClient.positions(key_id, pem, env),
         tickers <- Enum.map(positions, & &1.market_id) |> Enum.reject(&is_nil/1),
         {:ok, by_ticker} <- KalshiClient.markets_by_tickers(key_id, pem, tickers, env) do
      by_ticker
      |> Map.values()
      |> Enum.map(&enrich_with_orderbook(&1, key_id, pem, env))
      |> KalshiEdgeScorer.score_markets(now)
    else
      _ -> []
    end
  end

  # PR-K2: pull orderbook per ticker so the scorer can compute book
  # imbalance. Failure path returns the market unchanged — signal 2
  # contributes 0 pts (fail-soft per CyberSec ⑦ misshapen-input
  # guard); signal 1 still scores.
  defp enrich_with_orderbook(%{ticker: ticker} = market, key_id, pem, env)
       when is_binary(ticker) do
    case KalshiClient.orderbook(key_id, pem, ticker, env) do
      {:ok, ob} -> Map.merge(market, %{yes_levels: ob.yes_levels, no_levels: ob.no_levels})
      _ -> market
    end
  end

  defp enrich_with_orderbook(market, _key_id, _pem, _env), do: market

  defp authenticate(conn) do
    case conn.assigns[:current_agent] do
      %_{} = agent -> {:ok, agent}
      _ -> {:error, :unauthorized}
    end
  end

  defp serialize_score(score) do
    %{
      ticker: score.ticker,
      score: score.score,
      recommendation: score.recommendation,
      breakdown: score.breakdown,
      implied_prob: score.implied_prob,
      hours_to_close: score.hours_to_close,
      status: score.status
    }
  end
end
