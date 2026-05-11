defmodule KiteAgentHub.Kite.PortfolioEdgeScorer do
  @moduledoc """
  Scores current Alpaca + Kalshi positions and suggests new trades
  using QRB methodology.

  Position scores reflect how strong the current edge is on each holding.
  Suggestions come from scanning available Kalshi markets for mispriced contracts.

  Score breakdown (0-100):
    - Entry Quality (0-30): how good was the entry vs current price
    - Momentum (0-25): is the position moving in your favor
    - Risk/Reward (0-25): current R:R ratio based on entry and limits
    - Liquidity (0-20): can you exit cleanly
  """

  alias KiteAgentHub.{Credentials, Oanda}
  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient}

  # Top-of-book majors get a higher liquidity factor in the forex
  # scoring breakdown. Cross/exotic pairs ride a lower default.
  @forex_majors ~w(EUR_USD GBP_USD USD_JPY USD_CAD AUD_USD NZD_USD USD_CHF)

  @type recommendation :: :strong_hold | :hold | :watch | :exit
  @type position_score :: %{
          platform: :alpaca | :kalshi,
          score: non_neg_integer(),
          recommendation: recommendation(),
          pnl_pct: float(),
          breakdown: %{
            entry_quality: non_neg_integer(),
            momentum: non_neg_integer(),
            risk_reward: non_neg_integer(),
            liquidity: non_neg_integer()
          }
        }
  @type suggestion :: %{
          action: :exit | :hold,
          ticker: String.t(),
          platform: atom(),
          reason: String.t(),
          score: non_neg_integer()
        }
  @type portfolio_scores :: %{
          alpaca_scores: [position_score()],
          kalshi_scores: [position_score()],
          forex_scores: [position_score()],
          suggestions: [suggestion()],
          timestamp: DateTime.t()
        }

  @doc """
  Score all positions for the given org.

  Fetches current Alpaca and Kalshi positions, runs each through the
  QRB edge scorer, and surfaces up to 5 actionable exit/hold
  suggestions based on the scores.
  """
  @spec score_portfolio(Ecto.UUID.t()) :: portfolio_scores()
  def score_portfolio(org_id) do
    alpaca_scores = score_alpaca_positions(org_id)
    kalshi_scores = score_kalshi_positions(org_id)
    forex_scores = score_forex_positions(org_id)
    suggestions = generate_suggestions(kalshi_scores, alpaca_scores)

    %{
      alpaca_scores: alpaca_scores,
      kalshi_scores: kalshi_scores,
      forex_scores: forex_scores,
      suggestions: suggestions,
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Three-phase variant of `score_portfolio/1` for hot paths that
  cannot hold a Repo connection through the broker round-trip.

  Phase 1 (`Repo.with_user`): fetch Alpaca + Kalshi credentials —
  pure DB.
  Phase 2 (no Repo connection held): broker `positions` HTTP fan-out.
  Phase 3 (anywhere): score the positions, generate suggestions.

  Same return shape as `score_portfolio/1`; missing or unfetchable
  credentials yield empty score lists, identical to the single-phase
  fallback.
  """
  @spec score_portfolio_split(Ecto.UUID.t(), integer()) :: portfolio_scores()
  def score_portfolio_split(org_id, owner_user_id)
      when is_integer(owner_user_id) do
    # `Repo.with_user/2` wraps `transaction/1`, which always returns
    # `{:ok, value}` on success — destructure the outer `:ok` tuple
    # before binding the inner cred pair. Previously we bound directly
    # to `{alpaca_creds, kalshi_creds}`, which silently set
    # `alpaca_creds = :ok` and shoved both real creds into
    # `kalshi_creds`. The downstream `fetch_alpaca_positions(:ok)`
    # then fell through to the catch-all and returned `[]`, so every
    # agent's `score_portfolio_split` came back with empty
    # `alpaca_scores` + `kalshi_scores` regardless of real broker
    # state. KAH P1 2026-05-07: agent had 14 live Alpaca positions
    # but `RuleBasedStrategy` saw `scanning=0 positions` for everyone.
    {:ok, {alpaca_creds, kalshi_creds}} =
      KiteAgentHub.Repo.with_user(owner_user_id, fn ->
        {Credentials.fetch_secret_with_env(org_id, :alpaca),
         Credentials.fetch_secret_with_env(org_id, :kalshi)}
      end)

    # Phase 2 — Repo connection released; broker HTTP can take its
    # time without holding a pool slot.
    alpaca_positions = fetch_alpaca_positions(alpaca_creds)
    kalshi_positions = fetch_kalshi_positions(kalshi_creds)

    # Phase 3 — pure math; no IO.
    alpaca_scores = Enum.map(alpaca_positions, &score_alpaca_position/1)
    kalshi_scores = Enum.map(kalshi_positions, &score_kalshi_position/1)
    # Forex/OANDA positions live behind a separate credential and a
    # different HTTP host. score_forex_positions/1 does its own Repo +
    # broker round-trip — keep the split-mode parity simple by reusing
    # the single-phase path for now.
    forex_scores = score_forex_positions(org_id)
    suggestions = generate_suggestions(kalshi_scores, alpaca_scores)

    %{
      alpaca_scores: alpaca_scores,
      kalshi_scores: kalshi_scores,
      forex_scores: forex_scores,
      suggestions: suggestions,
      timestamp: DateTime.utc_now()
    }
  end

  defp fetch_alpaca_positions({:ok, {key_id, secret, env}}) do
    case AlpacaClient.positions(key_id, secret, env) do
      {:ok, positions} -> positions
      _ -> []
    end
  end

  defp fetch_alpaca_positions(_), do: []

  defp fetch_kalshi_positions({:ok, {key_id, pem, env}}) do
    case KalshiClient.positions(key_id, pem, env) do
      {:ok, positions} -> positions
      _ -> []
    end
  end

  defp fetch_kalshi_positions(_), do: []

  # ── Alpaca Position Scoring ──────────────────────────────────────────────────

  defp score_alpaca_positions(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.positions(key_id, secret, env) do
          {:ok, positions} -> Enum.map(positions, &score_alpaca_position/1)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp score_alpaca_position(pos) do
    entry = pos.avg_entry || 0.0
    current = pos.current_price || 0.0
    pnl_pct = if entry > 0, do: (current - entry) / entry * 100, else: 0.0

    entry_quality = score_entry_quality(pnl_pct)
    momentum = score_momentum(pnl_pct, pos.side)
    risk_reward = score_risk_reward(pnl_pct)
    # Alpaca equities generally liquid
    liquidity = 16

    total = entry_quality + momentum + risk_reward + liquidity

    %{
      platform: :alpaca,
      ticker: pos.symbol,
      side: pos.side,
      qty: pos.qty,
      # Propagate qty_available so RuleBasedStrategy can sell only what
      # is not already locked in a resting Alpaca order. Without this,
      # the strategy queues a duplicate sell every tick and Alpaca
      # rejects with HTTP 403 "insufficient qty available" — a
      # failed-row-per-tick loop until the stuck order is cancelled.
      qty_available: Map.get(pos, :qty_available),
      entry_price: entry,
      current_price: current,
      pnl_pct: Float.round(pnl_pct, 2),
      score: total,
      recommendation: recommend(total),
      breakdown: %{
        entry_quality: entry_quality,
        momentum: momentum,
        risk_reward: risk_reward,
        liquidity: liquidity
      }
    }
  end

  # ── Kalshi Position Scoring ──────────────────────────────────────────────────

  defp score_kalshi_positions(org_id) do
    case Credentials.fetch_secret_with_env(org_id, :kalshi) do
      {:ok, {key_id, pem, env}} ->
        case KalshiClient.positions(key_id, pem, env) do
          {:ok, positions} -> Enum.map(positions, &score_kalshi_position/1)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp score_kalshi_position(pos) do
    entry = pos.avg_price || 0.0
    current = pos.current_price || 0.0
    contracts = pos.contracts || 0

    # Kalshi: edge = how far current price moved from your entry
    pnl_pct = if entry > 0, do: (current - entry) / entry * 100, else: 0.0

    # Kalshi-specific: contracts near 0 or 100 cents have less edge remaining
    edge_remaining = min(current * 100, (1.0 - current) * 100) |> max(0)

    entry_quality = score_entry_quality(pnl_pct)
    momentum = score_kalshi_momentum(current, entry, pos.side)
    risk_reward = score_kalshi_rr(current, entry, pos.side)
    liquidity = if contracts > 0, do: 14, else: 8

    total = entry_quality + momentum + risk_reward + liquidity

    %{
      platform: :kalshi,
      ticker: pos.market_id,
      title: pos.title,
      side: pos.side,
      contracts: contracts,
      entry_price: entry,
      current_price: current,
      edge_remaining: Float.round(edge_remaining, 1),
      pnl_pct: Float.round(pnl_pct, 2),
      score: total,
      recommendation: recommend(total),
      breakdown: %{
        entry_quality: entry_quality,
        momentum: momentum,
        risk_reward: risk_reward,
        liquidity: liquidity
      }
    }
  end

  # ── Forex (OANDA) Position Scoring ──────────────────────────────────────────
  #
  # OANDA returns a single position row per instrument with both `long`
  # and `short` legs nested inside; only one carries non-zero units at
  # a time. We emit a score row per active leg. Scoring mirrors the
  # Alpaca/Kalshi shape (entry_quality / momentum / risk_reward /
  # liquidity) using pip-agnostic %-PnL as the input; liquidity is
  # bumped for top-of-book majors.

  defp score_forex_positions(org_id) do
    env = Oanda.active_env(org_id) || :practice

    case Oanda.list_positions(org_id, env) do
      positions when is_list(positions) ->
        Enum.flat_map(positions, &score_forex_position/1)

      _ ->
        []
    end
  end

  defp score_forex_position(%{"instrument" => instrument} = pos) when is_binary(instrument) do
    [
      forex_leg_score(pos, instrument, "long"),
      forex_leg_score(pos, instrument, "short")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp score_forex_position(_), do: []

  defp forex_leg_score(pos, instrument, side) do
    with leg when is_map(leg) <- pos[side],
         units when is_float(units) and units != 0.0 <-
           parse_oanda_float(leg["units"]),
         avg when is_float(avg) and avg > 0 <- parse_oanda_float(leg["averagePrice"]),
         upl when is_float(upl) <- parse_oanda_float(leg["unrealizedPL"]) || 0.0 do
      notional = abs(units) * avg
      pnl_pct = if notional > 0, do: upl / notional * 100, else: 0.0

      entry_quality = score_entry_quality(pnl_pct)
      momentum = score_momentum(pnl_pct, side)
      risk_reward = score_risk_reward(pnl_pct)
      liquidity = forex_liquidity(instrument)

      total = entry_quality + momentum + risk_reward + liquidity

      %{
        platform: :forex,
        ticker: instrument,
        side: side,
        qty: abs(units),
        entry_price: avg,
        # OANDA doesn't return a "current_price" on the positions
        # endpoint — derive a synthetic one from avg + per-unit PnL so
        # the response shape stays parallel to Alpaca/Kalshi.
        current_price:
          if abs(units) > 0 do
            sign = if side == "long", do: 1, else: -1
            avg + sign * upl / abs(units)
          else
            avg
          end,
        pnl_pct: Float.round(pnl_pct, 2),
        unrealized_pl: upl,
        score: total,
        recommendation: recommend(total),
        breakdown: %{
          entry_quality: entry_quality,
          momentum: momentum,
          risk_reward: risk_reward,
          liquidity: liquidity
        }
      }
    else
      _ -> nil
    end
  end

  defp forex_liquidity(instrument) when instrument in @forex_majors, do: 22
  defp forex_liquidity(_), do: 14

  defp parse_oanda_float(nil), do: nil

  defp parse_oanda_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_oanda_float(v) when is_float(v), do: v
  defp parse_oanda_float(v) when is_integer(v), do: v * 1.0
  defp parse_oanda_float(_), do: nil

  # ── Suggestions ──────────────────────────────────────────────────────────────

  defp generate_suggestions(kalshi_scores, alpaca_scores) do
    all = kalshi_scores ++ alpaca_scores

    # Suggest exiting weak positions
    weak = Enum.filter(all, &(&1.score < 40))

    exit_suggestions =
      Enum.map(weak, fn pos ->
        %{
          action: :exit,
          ticker: pos[:ticker] || pos[:title],
          platform: pos.platform,
          reason: "Edge score #{pos.score}/100 — below threshold. Consider closing.",
          score: pos.score
        }
      end)

    # Suggest holding strong positions
    strong = Enum.filter(all, &(&1.score >= 75))

    hold_suggestions =
      Enum.map(strong, fn pos ->
        %{
          action: :hold,
          ticker: pos[:ticker] || pos[:title],
          platform: pos.platform,
          reason: "Strong edge #{pos.score}/100 — maintain position.",
          score: pos.score
        }
      end)

    (exit_suggestions ++ hold_suggestions)
    |> Enum.sort_by(& &1.score)
    |> Enum.take(5)
  end

  # ── Scoring Helpers ──────────────────────────────────────────────────────────

  defp score_entry_quality(pnl_pct) do
    cond do
      pnl_pct >= 10 -> 30
      pnl_pct >= 5 -> 25
      pnl_pct >= 2 -> 20
      pnl_pct >= 0 -> 15
      pnl_pct >= -2 -> 10
      pnl_pct >= -5 -> 5
      true -> 0
    end
  end

  defp score_momentum(pnl_pct, side) do
    # Positive P&L means momentum is with you
    favorable = (side == "long" and pnl_pct > 0) or (side == "short" and pnl_pct < 0)
    magnitude = abs(pnl_pct)

    cond do
      favorable and magnitude >= 5 -> 25
      favorable and magnitude >= 2 -> 20
      favorable -> 15
      magnitude < 1 -> 12
      magnitude < 3 -> 8
      true -> 3
    end
  end

  defp score_kalshi_momentum(current, entry, side) do
    moving_right = (side == "yes" and current > entry) or (side == "no" and current < entry)
    gap = abs(current - entry) * 100

    cond do
      moving_right and gap >= 10 -> 25
      moving_right and gap >= 5 -> 20
      moving_right -> 15
      gap < 3 -> 12
      true -> 5
    end
  end

  defp score_risk_reward(pnl_pct) do
    cond do
      pnl_pct >= 5 -> 25
      pnl_pct >= 2 -> 20
      pnl_pct >= 0 -> 15
      pnl_pct >= -2 -> 10
      pnl_pct >= -5 -> 5
      true -> 0
    end
  end

  defp score_kalshi_rr(current, _entry, side) do
    # For YES: potential = (1.0 - current) if you're long, risk = current
    # For NO: potential = current if you're short, risk = (1.0 - current)
    {potential, risk} =
      case side do
        "yes" -> {1.0 - current, current}
        "no" -> {current, 1.0 - current}
        _ -> {0.5, 0.5}
      end

    ratio = if risk > 0, do: potential / risk, else: 0

    cond do
      ratio >= 3.0 -> 25
      ratio >= 2.0 -> 20
      ratio >= 1.5 -> 15
      ratio >= 1.0 -> 10
      ratio >= 0.5 -> 5
      true -> 0
    end
  end

  defp recommend(score) when score >= 75, do: :strong_hold
  defp recommend(score) when score >= 60, do: :hold
  defp recommend(score) when score >= 40, do: :watch
  defp recommend(_score), do: :exit
end
