defmodule KiteAgentHubWeb.API.HistoricalTradesController do
  @moduledoc """
  REST endpoint exposing the agents own bucketed historical trade
  outcomes — totals, per-platform aggregates, per-market aggregates,
  and a recent-fills sample. Mirrors the shape an agent reasons about
  (sample size, win rate, P&L) so the LLM can self-reflect without
  pulling every raw row.

  Distinct from `/collective-intelligence` (which is the workspace-
  anonymized cross-org corpus). This endpoint is always agent-scoped
  to the bearer-token agent — no cross-agent leak.

  ## Endpoint

      GET /api/v1/historical-trades
      GET /api/v1/historical-trades?platform=oanda&days=30&limit=50

  ## Query params

    * `platform` — restrict to one of `alpaca|kalshi|oanda|kite`. Omit for all.
    * `days`     — only include trades settled in the last N days. Omit for all-time.
    * `limit`    — recent-fills sample size, clamped 1..100. Default 20.

  Auth: Bearer agent api_token (same as other /api/v1 endpoints).
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Api.RateLimiter

  def index(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- RateLimiter.check(agent.id) do
      # Clamp limit here so the echoed filters.limit reflects what the
      # query actually used (helps the agent calibrate paging).
      effective_limit = (parse_pos_int(params["limit"]) || 20) |> max(1) |> min(100)

      opts =
        [
          platform: parse_platform(params["platform"]),
          days: parse_pos_int(params["days"]),
          limit: effective_limit
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      data = Trading.historical_trades_summary(agent.id, opts)

      conn
      |> json(%{
        ok: true,
        agent_id: agent.id,
        filters: %{
          platform: params["platform"],
          days: params["days"],
          limit: effective_limit
        },
        summary: serialize_summary(data.summary),
        by_platform: Enum.map(data.by_platform, &serialize_bucket/1),
        by_market: Enum.map(data.by_market, &serialize_bucket/1),
        recent: Enum.map(data.recent, &serialize_trade/1)
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{ok: false, error: "rate limited"})
    end
  end

  defp serialize_summary(nil),
    do: %{
      settled_trades: 0,
      total_pnl: "0",
      win_count: 0,
      loss_count: 0,
      flat_count: 0,
      win_rate: nil,
      avg_pnl: nil
    }

  defp serialize_summary(%{} = s) do
    settled = s.settled_trades || 0
    wins = s.win_count || 0
    losses = s.loss_count || 0
    flats = s.flat_count || 0
    pnl = s.total_pnl || Decimal.new(0)
    decided = wins + losses

    %{
      settled_trades: settled,
      total_pnl: Decimal.to_string(pnl, :normal),
      win_count: wins,
      loss_count: losses,
      flat_count: flats,
      win_rate: if(decided > 0, do: Float.round(wins / decided, 4), else: nil),
      avg_pnl:
        if(settled > 0,
          do:
            pnl
            |> Decimal.div(Decimal.new(settled))
            |> Decimal.to_string(:normal),
          else: nil
        )
    }
  end

  defp serialize_bucket(%{} = row) do
    wins = row[:wins] || 0
    losses = row[:losses] || 0
    decided = wins + losses
    pnl = row[:pnl] || Decimal.new(0)

    base = %{
      trades: row.trades,
      wins: wins,
      losses: losses,
      pnl: Decimal.to_string(pnl, :normal),
      win_rate: if(decided > 0, do: Float.round(wins / decided, 4), else: nil)
    }

    cond do
      Map.has_key?(row, :platform) -> Map.put(base, :platform, row.platform)
      Map.has_key?(row, :market) -> Map.put(base, :market, row.market)
      true -> base
    end
  end

  defp serialize_trade(trade) do
    %{
      id: trade.id,
      platform: trade.platform,
      market: trade.market,
      side: trade.side,
      action: trade.action,
      contracts: trade.contracts && Decimal.to_string(trade.contracts, :normal),
      fill_price: trade.fill_price && Decimal.to_string(trade.fill_price, :normal),
      realized_pnl: trade.realized_pnl && Decimal.to_string(trade.realized_pnl, :normal),
      status: trade.status,
      attestation_tx_hash: trade.attestation_tx_hash,
      settled_at: trade.updated_at
    }
  end

  defp parse_platform(p) when p in ["alpaca", "kalshi", "oanda", "kite"], do: p
  defp parse_platform(_), do: nil

  defp parse_pos_int(nil), do: nil
  defp parse_pos_int(""), do: nil

  defp parse_pos_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_pos_int(n) when is_integer(n) and n > 0, do: n
  defp parse_pos_int(_), do: nil

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
end
