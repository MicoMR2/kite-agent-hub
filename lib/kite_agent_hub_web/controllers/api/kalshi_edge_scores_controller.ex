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
  agent has positions in on the time-decay / closeout edge — the
  underlying-event signal closer to a Kelly-style EV read.

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
      |> KalshiEdgeScorer.score_markets(now)
    else
      _ -> []
    end
  end

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
