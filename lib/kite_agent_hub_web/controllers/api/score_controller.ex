defmodule KiteAgentHubWeb.API.ScoreController do
  @moduledoc """
  REST endpoint for external LLMs to score a hypothetical NEW entry on
  any ticker. Where `/api/v1/edge-scores` only ranks positions the agent
  already holds, this endpoint answers "should I open a position in
  TICKER right now?" — driven by recent OHLCV bars from the Alpaca
  market data API and the QRB-style entry scoring in
  `KiteAgentHub.Kite.TickerScorer`.

  Auth: `Authorization: Bearer <agent_api_token>` — same scheme as
  `/api/v1/trades`, `/api/v1/chat`, and `/api/v1/edge-scores`. Alpaca
  credentials are pulled from the encrypted DB column scoped to the
  agent's organization — the agent never holds raw Alpaca keys.

  ## Endpoints

    GET  /api/v1/score?ticker=AAPL[&timeframe=1Day&limit=50]
    POST /api/v1/score/batch   body: {"tickers": ["AAPL", "MSFT"],
                                       "timeframe": "1Day",
                                       "limit": 50}

  Supported `timeframe` values: `1Min`, `5Min`, `15Min`, `1Hour`, `1Day`
  (default `1Day`). `limit` is 1..1000 (default 50).

  Batch is capped at 25 tickers per request so a single caller cannot
  exhaust the Alpaca data-tier quota (200 req/min free tier). The
  controller fetches bars serially — `AlpacaClient.bars/5` already
  honors Retry-After on 429, so a temporary burst backpressures
  cleanly instead of failing the whole batch.

  ## Response (single)

    {
      "ok": true,
      "ticker": "AAPL",
      "timeframe": "1Day",
      "score": 78,
      "signal": "buy",
      ...
    }

  ## Response (batch)

    {
      "ok": true,
      "timeframe": "1Day",
      "limit": 50,
      "scores": [
        {"ok": true, "ticker": "AAPL", "score": 78, ...},
        {"ok": false, "ticker": "ZZZ", "error": "no bars returned"}
      ]
    }
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.Kite.TickerScorer
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  @supported_timeframes ~w(1Min 5Min 15Min 1Hour 1Day)
  @default_timeframe "1Day"
  @default_limit 50
  @max_limit 1000
  @max_batch_size 25

  # ── GET /api/v1/score ─────────────────────────────────────────────────────────

  def show(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, ticker} <- fetch_ticker(params),
         {:ok, timeframe} <- fetch_timeframe(params),
         {:ok, limit} <- fetch_limit(params),
         {:ok, {key_id, secret, _env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca),
         {:ok, bars} <- AlpacaClient.bars(key_id, secret, ticker, timeframe, limit) do
      case TickerScorer.score_ticker(ticker, bars) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{ok: false, error: "no bars returned for #{ticker}"})

        score ->
          # Bar close runs a day behind until 4pm ET on 1Day timeframes.
          # Batch scoring was returning last_price ~8% below live on
          # intraday moves. Snapshot endpoint gives the latest trade
          # print; fall back to bar close if snapshot is missing/nil
          # (CyberSec guardrail, msg 6395).
          live_prices = fetch_live_prices(key_id, secret, [ticker])
          score = override_last_price(score, live_prices)

          conn |> json(Map.merge(%{ok: true, timeframe: timeframe}, serialize_score(score)))
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :missing_ticker} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "ticker query param is required"})

      {:error, :bad_timeframe} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          ok: false,
          error: "timeframe must be one of #{Enum.join(@supported_timeframes, ", ")}"
        })

      {:error, :bad_limit} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "limit must be an integer between 1 and #{@max_limit}"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured for this org"})

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{ok: false, error: "alpaca rate limit — retry after a few seconds"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "scoring failed: #{inspect(reason)}"})
    end
  end

  # ── POST /api/v1/score/batch ──────────────────────────────────────────────────

  def batch(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, tickers} <- fetch_tickers(params),
         {:ok, timeframe} <- fetch_timeframe(params),
         {:ok, limit} <- fetch_limit(params),
         {:ok, {key_id, secret, _env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
      # One snapshots call for the whole batch — cheap and keeps
      # last_price fresh across every scored ticker.
      live_prices = fetch_live_prices(key_id, secret, tickers)

      scores =
        Enum.map(tickers, fn ticker ->
          score_one(key_id, secret, ticker, timeframe, limit, live_prices)
        end)

      conn
      |> json(%{ok: true, timeframe: timeframe, limit: limit, scores: scores})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :missing_tickers} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "tickers must be a non-empty array of symbols"})

      {:error, :too_many_tickers} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "batch capped at #{@max_batch_size} tickers per request"})

      {:error, :bad_timeframe} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          ok: false,
          error: "timeframe must be one of #{Enum.join(@supported_timeframes, ", ")}"
        })

      {:error, :bad_limit} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "limit must be an integer between 1 and #{@max_limit}"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured for this org"})
    end
  end

  # Per-ticker scoring inside a batch — failures come back as
  # `{ok: false, ticker, error}` rows so one bad symbol never fails
  # the whole batch. `live_prices` is the snapshot map from the
  # batch-level fetch; missing entries fall back silently to the
  # bar-close last_price so one unavailable symbol doesn't degrade
  # the rest of the batch.
  defp score_one(key_id, secret, ticker, timeframe, limit, live_prices) do
    case AlpacaClient.bars(key_id, secret, ticker, timeframe, limit) do
      {:ok, bars} ->
        case TickerScorer.score_ticker(ticker, bars) do
          nil ->
            %{ok: false, ticker: ticker, error: "no bars returned"}

          score ->
            score = override_last_price(score, live_prices)
            Map.merge(%{ok: true}, serialize_score(score))
        end

      {:error, :rate_limited} ->
        %{ok: false, ticker: ticker, error: "rate limited"}

      {:error, reason} ->
        %{ok: false, ticker: ticker, error: "bars fetch failed: #{inspect(reason)}"}
    end
  end

  # Pull latest-trade prices for a list of tickers. Failures are
  # treated as "no override" — the caller falls back to the bar-close
  # last_price from the TickerScorer output. Never raises, never
  # returns nil — always an empty-or-populated map.
  defp fetch_live_prices(key_id, secret, tickers) do
    case AlpacaClient.snapshots(key_id, secret, tickers) do
      {:ok, prices} when is_map(prices) -> prices
      _ -> %{}
    end
  end

  defp override_last_price(%{ticker: ticker} = score, live_prices) do
    case Map.get(live_prices, ticker) do
      price when is_number(price) and price > 0 -> %{score | last_price: price}
      _ -> score
    end
  end

  defp serialize_score(score) do
    %{
      ticker: score.ticker,
      score: score.score,
      signal: score.signal,
      last_price: score.last_price,
      sma_20: score.sma_20,
      change_5d_pct: score.change_5d_pct,
      change_20d_pct: score.change_20d_pct,
      avg_volume: score.avg_volume,
      breakdown: score.breakdown
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

  # Tickers are uppercase letters/digits only, max 8 chars — defends
  # against URL-injection by refusing anything that doesn't look like a
  # real symbol before forwarding it to the Alpaca data API.
  defp fetch_ticker(%{"ticker" => raw}) when is_binary(raw) do
    case normalize_ticker(raw) do
      {:ok, t} -> {:ok, t}
      :error -> {:error, :missing_ticker}
    end
  end

  defp fetch_ticker(_), do: {:error, :missing_ticker}

  defp fetch_tickers(%{"tickers" => list}) when is_list(list) and list != [] do
    normalized =
      list
      |> Enum.map(&normalize_ticker/1)
      |> Enum.reduce_while([], fn
        {:ok, t}, acc -> {:cont, [t | acc]}
        :error, _ -> {:halt, :bad}
      end)

    case normalized do
      :bad -> {:error, :missing_tickers}
      [] -> {:error, :missing_tickers}
      tickers when length(tickers) > @max_batch_size -> {:error, :too_many_tickers}
      tickers -> {:ok, Enum.reverse(tickers) |> Enum.uniq()}
    end
  end

  defp fetch_tickers(_), do: {:error, :missing_tickers}

  defp normalize_ticker(raw) when is_binary(raw) do
    candidate = raw |> String.trim() |> String.upcase()

    if Regex.match?(~r/\A[A-Z0-9]{1,8}\z/, candidate) do
      {:ok, candidate}
    else
      :error
    end
  end

  defp normalize_ticker(_), do: :error

  defp fetch_timeframe(params) do
    case Map.get(params, "timeframe", @default_timeframe) do
      tf when tf in @supported_timeframes -> {:ok, tf}
      _ -> {:error, :bad_timeframe}
    end
  end

  defp fetch_limit(params) do
    case Map.get(params, "limit", @default_limit) do
      n when is_integer(n) and n >= 1 and n <= @max_limit ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 1 and n <= @max_limit -> {:ok, n}
          _ -> {:error, :bad_limit}
        end

      _ ->
        {:error, :bad_limit}
    end
  end
end
