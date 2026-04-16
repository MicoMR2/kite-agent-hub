defmodule KiteAgentHubWeb.API.EdgeScoresHistoryController do
  @moduledoc """
  Historical QRB edge-score series for the authenticated agent's org.
  Backs "strategy-agent called a momentum inflection" reads like
  HAL 96 → 91 → 85 → trim. Phorari PR #6 (msg 6274 + scope 9975).

  ## Endpoint

    GET /api/v1/edge-scores/history[?ticker=HAL&hours=24&platform=alpaca&limit=500]

  - `ticker`   : case-sensitive exact match (uppercase letters/digits
    ≤16 chars — matches Kalshi contract ids and equity symbols).
    Optional; omit to return every ticker in the org.
  - `hours`    : 1..168 (1 week max), default 24.
  - `platform` : "alpaca" | "kalshi". Optional.
  - `limit`    : 1..2000, default 500.

  ## Response

    {
      "ok": true,
      "hours": 24,
      "count": 72,
      "snapshots": [
        {
          "ticker": "HAL",
          "platform": "alpaca",
          "score": 91,
          "breakdown": {...},
          "recommendation": "hold",
          "pnl_pct": 0.14,
          "inserted_at": "2026-04-16T18:15:00Z"
        }
      ]
    }

  Auth: Bearer agent api_token (same as every other /api/v1 route).
  Snapshots are org-scoped — agents can only read their own org's
  history.
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Trading

  @max_hours 168
  @max_limit 2000
  @default_hours 24
  @default_limit 500

  def index(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, opts} <- parse_opts(params) do
      rows = Trading.list_edge_score_history(agent.organization_id, opts)

      conn
      |> json(%{
        ok: true,
        hours: Keyword.fetch!(opts, :hours),
        count: length(rows),
        snapshots: Enum.map(rows, &serialize/1)
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :bad_ticker} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "ticker must be alphanumeric (max 16 chars)"})

      {:error, :bad_hours} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "hours must be an integer between 1 and #{@max_hours}"})

      {:error, :bad_limit} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "limit must be an integer between 1 and #{@max_limit}"})

      {:error, :bad_platform} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "platform must be alpaca or kalshi"})
    end
  end

  defp parse_opts(params) do
    with {:ok, hours} <- fetch_int(params, "hours", @default_hours, 1, @max_hours, :bad_hours),
         {:ok, limit} <- fetch_int(params, "limit", @default_limit, 1, @max_limit, :bad_limit),
         {:ok, ticker} <- fetch_ticker(params),
         {:ok, platform} <- fetch_platform(params) do
      opts = [hours: hours, limit: limit]
      opts = if ticker, do: [{:ticker, ticker} | opts], else: opts
      opts = if platform, do: [{:platform, platform} | opts], else: opts
      {:ok, opts}
    end
  end

  defp fetch_int(params, field, default, min, max, err_atom) do
    case Map.get(params, field, default) do
      n when is_integer(n) and n >= min and n <= max ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= min and n <= max -> {:ok, n}
          _ -> {:error, err_atom}
        end

      _ ->
        {:error, err_atom}
    end
  end

  defp fetch_ticker(%{"ticker" => raw}) when is_binary(raw) and raw != "" do
    candidate = raw |> String.trim() |> String.upcase()

    if Regex.match?(~r/\A[A-Z0-9\-]{1,16}\z/, candidate) do
      {:ok, candidate}
    else
      {:error, :bad_ticker}
    end
  end

  defp fetch_ticker(_), do: {:ok, nil}

  defp fetch_platform(%{"platform" => raw}) when is_binary(raw) and raw != "" do
    case String.downcase(raw) do
      p when p in ["alpaca", "kalshi"] -> {:ok, p}
      _ -> {:error, :bad_platform}
    end
  end

  defp fetch_platform(_), do: {:ok, nil}

  defp serialize(row) do
    %{
      ticker: row.ticker,
      platform: row.platform,
      score: row.score,
      breakdown: row.breakdown,
      recommendation: row.recommendation,
      pnl_pct: row.pnl_pct,
      inserted_at: row.inserted_at
    }
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
end
