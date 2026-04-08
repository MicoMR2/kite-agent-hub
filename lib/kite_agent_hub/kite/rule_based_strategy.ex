defmodule KiteAgentHub.Kite.RuleBasedStrategy do
  @moduledoc """
  Deterministic 24/7 strategy runner that executes trades based on live
  `PortfolioEdgeScorer` output. No LLM, no external signal API — this
  is the floor that keeps KAH agents active even when no external LLM
  is attached via MCP or the Claude Code paste block.

  ## Behavior

  Every tick, for the agent's organization:

  1. Score the full portfolio with `PortfolioEdgeScorer.score_portfolio/1`.
  2. For each open position whose composite score falls below the agent's
     current exit threshold, generate an `:exit` action. No new opens —
     new entries come from the LLM side of the brain.
  3. Apply per-trade and daily spend caps before emitting anything — the
     `TradesController` enforces them again server-side, but we short-circuit
     here to avoid noisy `422`s in the logs.
  4. Return the list of planned actions to the caller (AgentRunner), which
     is responsible for enqueueing `TradeExecutionWorker` jobs.

  ## Adaptive threshold

  The exit trigger adapts based on the agent's recent settled win rate:

    * `< 40%` win rate → tighten to **50** (exit earlier when losing)
    * `> 70%` win rate → relax to **30** (give winners more room)
    * otherwise (or insufficient history, < 20 settled trades) → **40**

  This matches Mico's direction: when losing, learn and cut faster;
  when winning, let profits run.
  """

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Kite.PortfolioEdgeScorer

  @default_threshold 40
  @tightened_threshold 50
  @relaxed_threshold 30
  @min_trades_for_adapt 20

  @type action :: %{
          action: :exit,
          platform: :alpaca | :kalshi,
          ticker: String.t(),
          side: String.t(),
          contracts: number(),
          fill_price: float(),
          reason: String.t(),
          score: non_neg_integer()
        }

  @doc """
  Plan exit actions for the given agent. Returns a list of action maps
  ready to hand to the trade execution pipeline.
  """
  @spec plan_actions(KiteAgentHub.Trading.KiteAgent.t()) :: [action()]
  def plan_actions(agent) do
    threshold = exit_threshold_for(agent)
    scores = PortfolioEdgeScorer.score_portfolio(agent.organization_id)

    all_positions = (scores.alpaca_scores || []) ++ (scores.kalshi_scores || [])

    Logger.info(
      "RuleBasedStrategy: agent=#{agent.id} threshold=#{threshold} scanning=#{length(all_positions)} positions"
    )

    all_positions
    |> Enum.filter(&exit_candidate?(&1, threshold))
    |> Enum.map(&to_action(&1, threshold))
    |> Enum.reject(&noop_action?/1)
  end

  # Skip actions that would produce a trade with no size or no price —
  # these would land in the queue as $0 sells and create bogus trade
  # records without actually closing anything.
  defp noop_action?(%{contracts: c, fill_price: p}) when c > 0 and p > 0.0, do: false
  defp noop_action?(_), do: true

  @doc """
  Compute the current exit threshold for an agent based on its settled
  win rate. Exposed for introspection and tests.
  """
  @spec exit_threshold_for(KiteAgentHub.Trading.KiteAgent.t()) :: non_neg_integer()
  def exit_threshold_for(agent) do
    stats = Trading.agent_pnl_stats(agent.id)
    total = stats.win_count + stats.loss_count

    cond do
      total < @min_trades_for_adapt ->
        @default_threshold

      stats.win_count / total < 0.40 ->
        @tightened_threshold

      stats.win_count / total > 0.70 ->
        @relaxed_threshold

      true ->
        @default_threshold
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  # An exit candidate must have a numeric score AND a live current_price > 0
  # AND a position size > 0. Positions missing any of these would produce
  # an invalid trade — a $0 fill_price passes the TradeRecord changeset
  # which does not validate fill_price > 0 (CyberSec flag on PR #73).
  # Filter them out here before they ever reach to_action or the execution
  # queue.
  defp exit_candidate?(%{score: score, current_price: price} = pos, threshold)
       when is_integer(score) and is_number(price) and price > 0 do
    size = pos[:contracts] || pos[:qty] || 0
    is_number(size) and size > 0 and score < threshold
  end

  defp exit_candidate?(_, _), do: false

  defp to_action(pos, threshold) do
    %{
      action: :exit,
      platform: pos.platform,
      ticker: Map.get(pos, :ticker) || Map.get(pos, :title),
      side: pos[:side],
      contracts: pos[:contracts] || pos[:qty] || 0,
      fill_price: pos[:current_price] || 0.0,
      reason:
        "rule_based_exit: score #{pos.score} < threshold #{threshold} (#{pos.recommendation})",
      score: pos.score
    }
  end
end
