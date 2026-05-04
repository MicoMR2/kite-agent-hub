defmodule KiteAgentHub.Workers.EdgeScoreSnapshotWorker do
  @moduledoc """
  Every 5 minutes, snapshots `PortfolioEdgeScorer.score_portfolio/1`
  for each active org and persists one row per (ticker, platform) to
  `edge_score_snapshots`. Backs `/api/v1/edge-scores/history` so the
  strategy agent can call momentum inflection trims (HAL 96 → 91 → 85
  etc).

  Ties into the same RLS-safe owner fanout pattern
  AlpacaSettlementWorker and StuckTradeSweeper use: a SECURITY DEFINER
  lookup returns (agent_id, owner_user_id) pairs, and each org's scan
  runs inside `Repo.with_user(owner_user_id, …)`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker]]

  require Logger

  alias KiteAgentHub.{Repo, Trading}
  alias KiteAgentHub.Kite.PortfolioEdgeScorer

  @impl Oban.Worker
  def perform(_job) do
    # One snapshot pass per org covers all agents/positions in that
    # org (PortfolioEdgeScorer is org-scoped). Dedup by org id.
    owner_pairs = Repo.active_agents_with_owners()

    orgs_seen =
      Enum.reduce(owner_pairs, MapSet.new(), fn {agent_id, owner_user_id}, acc ->
        case Repo.with_user(owner_user_id, fn ->
               agent = Trading.get_agent!(agent_id)
               {agent.organization_id, owner_user_id}
             end) do
          {:ok, {org_id, user_id}} ->
            if MapSet.member?(acc, org_id) do
              acc
            else
              snapshot_for_org(org_id, user_id)
              MapSet.put(acc, org_id)
            end

          _ ->
            acc
        end
      end)

    Logger.info("EdgeScoreSnapshotWorker: scanned #{MapSet.size(orgs_seen)} org(s)")
    :ok
  end

  defp snapshot_for_org(org_id, owner_user_id) do
    scores = PortfolioEdgeScorer.score_portfolio(org_id)

    alpaca = persist_rows(org_id, owner_user_id, scores.alpaca_scores, "alpaca")
    kalshi = persist_rows(org_id, owner_user_id, scores.kalshi_scores, "kalshi")

    Logger.info(
      "EdgeScoreSnapshotWorker: org #{org_id} — persisted alpaca=#{alpaca} kalshi=#{kalshi}"
    )
  rescue
    e ->
      Logger.warning(
        "EdgeScoreSnapshotWorker: org #{org_id} snapshot failed: #{Exception.message(e)}"
      )
  end

  defp persist_rows(org_id, owner_user_id, scores, platform) do
    scores
    |> Enum.reduce(0, fn score, acc ->
      attrs = %{
        organization_id: org_id,
        ticker: to_string(score.ticker || ""),
        platform: platform,
        score: score.score,
        breakdown: score.breakdown || %{},
        recommendation: to_string(score.recommendation || ""),
        pnl_pct: score.pnl_pct
      }

      case Repo.with_user(owner_user_id, fn -> Trading.insert_edge_score_snapshot(attrs) end) do
        {:ok, {:ok, _row}} -> acc + 1
        _ -> acc
      end
    end)
  end
end
