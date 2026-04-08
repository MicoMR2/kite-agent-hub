defmodule KiteAgentHubWeb.API.EdgeScoresController do
  @moduledoc """
  REST endpoint for external LLMs to pull live QRB edge scores for the
  authenticated agent's organization.

  Auth: `Authorization: Bearer <agent_api_token>` — same token scheme as
  `/api/v1/trades` and `/api/v1/chat`.

  Returns the JSON-serialized output of `KiteAgentHub.Kite.PortfolioEdgeScorer.score_portfolio/1`
  — current Alpaca + Kalshi positions, each scored 0-100 with the four-factor
  QRB breakdown (entry_quality, momentum, risk_reward, liquidity), plus a short
  list of exit/hold suggestions.
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Kite.PortfolioEdgeScorer

  def index(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      scores = PortfolioEdgeScorer.score_portfolio(agent.organization_id)

      conn
      |> json(%{
        ok: true,
        timestamp: DateTime.to_iso8601(scores.timestamp),
        alpaca_scores: Enum.map(scores.alpaca_scores, &serialize_score/1),
        kalshi_scores: Enum.map(scores.kalshi_scores, &serialize_score/1),
        suggestions: Enum.map(scores.suggestions, &serialize_suggestion/1)
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  # Auth is via the secret agent api_token ONLY. Wallet addresses are
  # public on-chain and must never be accepted as a credential.
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

  defp serialize_score(score) do
    %{
      platform: score.platform,
      ticker: Map.get(score, :ticker) || Map.get(score, :title),
      side: score.side,
      score: score.score,
      recommendation: score.recommendation,
      pnl_pct: score.pnl_pct,
      entry_price: Map.get(score, :entry_price),
      current_price: Map.get(score, :current_price),
      breakdown: score.breakdown
    }
  end

  defp serialize_suggestion(sug) do
    %{
      action: sug.action,
      ticker: sug.ticker,
      platform: sug.platform,
      reason: sug.reason,
      score: sug.score
    }
  end
end
