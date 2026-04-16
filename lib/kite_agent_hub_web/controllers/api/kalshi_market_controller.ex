defmodule KiteAgentHubWeb.API.KalshiMarketController do
  @moduledoc """
  Scans Kalshi markets and returns contracts scoring above a threshold,
  sorted desc by score. Phorari PR #5 (msg 6274 + 6316). Lets Research
  surface NEW Kalshi contracts without polling the Kalshi public API
  by hand.

  ## Endpoint

    GET /api/v1/market-data/kalshi[?min_score=70&limit=200&status=open]

  - `min_score` : 0..100, default 0 (no filter).
  - `limit`     : Kalshi page size, 1..1000, default 200.
  - `status`    : Kalshi market status filter (`open`, `closed`,
    `settled`); only `open` is tradeable so it's the default.

  Scoring formula lives in `KiteAgentHub.Kite.KalshiMarketScorer`.

  ## Response

    {
      "ok": true,
      "count": 42,
      "min_score": 70,
      "markets": [
        {
          "ticker": "KXPRES-24NOV05-DJT",
          "score": 88,
          "volume_24h": 12453,
          "yes_bid": 52,
          "yes_ask": 54,
          "spread_cents": 2,
          "status": "open",
          "close_time": "...",
          "title": "..."
        }
      ]
    }

  Auth: Bearer agent api_token. Kalshi credentials (access key + PEM)
  sourced per-org via `Credentials.fetch_secret_with_env(org_id, :kalshi)`.
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.Kite.KalshiMarketScorer
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  @default_min_score 0
  @default_limit 200
  @max_limit 1000
  @default_status "open"

  def show(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, min_score} <- fetch_int(params, "min_score", @default_min_score, 0, 100),
         {:ok, limit} <- fetch_int(params, "limit", @default_limit, 1, @max_limit),
         {:ok, status} <- fetch_status(params),
         {:ok, {key_id, pem, env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :kalshi),
         {:ok, markets} <- KalshiClient.list_markets(key_id, pem, status: status, limit: limit, env: env) do
      scored = KalshiMarketScorer.score_markets(markets, min_score)

      conn
      |> json(%{ok: true, count: length(scored), min_score: min_score, markets: scored})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :bad_int, field} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "#{field} must be within allowed range"})

      {:error, :bad_status} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "status must be alphanumeric"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "kalshi credentials not configured for this org"})

      {:error, reason} ->
        Logger.warning("KalshiMarketController: upstream fetch failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "kalshi scan failed: #{inspect(reason)}"})
    end
  end

  defp fetch_int(params, field, default, min, max) do
    case Map.get(params, field, default) do
      n when is_integer(n) and n >= min and n <= max ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= min and n <= max -> {:ok, n}
          _ -> {:error, :bad_int, field}
        end

      _ ->
        {:error, :bad_int, field}
    end
  end

  defp fetch_status(params) do
    raw = Map.get(params, "status", @default_status) |> to_string() |> String.trim()

    if Regex.match?(~r/\A[a-z_]{1,24}\z/, raw) do
      {:ok, raw}
    else
      {:error, :bad_status}
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
end
