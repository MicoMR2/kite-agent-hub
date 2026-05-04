defmodule KiteAgentHubWeb.API.StreamController do
  @moduledoc """
  JSON API for managing Alpaca real-time WebSocket streaming feeds.

  All endpoints require the standard agent `Authorization: Bearer <api_token>`.
  The streaming feed connects using the **org's** Alpaca credentials (not the
  agent's), so any agent in the org can start/stop feeds.

  ## Endpoints

      POST   /api/v1/stream/start   — start a feed (or add symbols to existing)
      DELETE /api/v1/stream/stop    — stop a feed
      GET    /api/v1/stream/status  — list running feeds and their status

  ## POST /api/v1/stream/start

  Body:

      {
        "feed": "stocks",          // "stocks" | "crypto" | "news"
        "symbols": ["AAPL", "SPY"], // symbols to subscribe to
        "topics": ["trades", "quotes"] // optional; default ["trades", "quotes"]
      }

  Returns `{"ok": true, "feed": "stocks", "status": "started"}` or
  `{"ok": true, "feed": "stocks", "status": "symbols_added"}` if the feed
  was already running.

  ## DELETE /api/v1/stream/stop

  Body: `{"feed": "stocks"}`

  Returns `{"ok": true}` or `{"error": "not_found"}`.

  ## GET /api/v1/stream/status

  Returns `{"feeds": [{"feed": "stocks", "status": "connected"}]}`.
  """

  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.TradingPlatforms.{AlpacaStream, AlpacaStreamSupervisor}

  @valid_feeds ~w(stocks crypto news)

  def start(conn, params) do
    feed_str = params["feed"]
    symbols = params["symbols"] || []
    topics = params["topics"] || ["trades", "quotes"]

    with {:ok, org_id} <- resolve_org(conn),
         {:ok, feed} <- parse_feed(feed_str) do
      result =
        case AlpacaStream.status(feed) do
          :not_started ->
            AlpacaStreamSupervisor.start_feed(feed, org_id, symbols: symbols, topics: topics)
            "started"

          _ ->
            if symbols != [] do
              AlpacaStream.add_symbols(feed, symbols)
            end

            "symbols_added"
        end

      Logger.info("StreamController: #{result} feed=#{feed} symbols=#{inspect(symbols)}")
      json(conn, %{ok: true, feed: feed_str, status: result})
    else
      {:error, :no_org} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :invalid_feed} ->
        conn |> put_status(422) |> json(%{error: "invalid feed; must be stocks, crypto, or news"})
    end
  end

  def stop(conn, params) do
    feed_str = params["feed"]

    with {:ok, _org_id} <- resolve_org(conn),
         {:ok, feed} <- parse_feed(feed_str) do
      case AlpacaStreamSupervisor.stop_feed(feed) do
        :ok ->
          Logger.info("StreamController: stopped feed=#{feed}")
          json(conn, %{ok: true})

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "not_found"})
      end
    else
      {:error, :no_org} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      {:error, :invalid_feed} ->
        conn |> put_status(422) |> json(%{error: "invalid feed"})
    end
  end

  def status(conn, _params) do
    with {:ok, _org_id} <- resolve_org(conn) do
      feeds =
        Enum.map(@valid_feeds, fn feed_str ->
          feed = String.to_atom(feed_str)
          %{feed: feed_str, status: Atom.to_string(AlpacaStream.status(feed))}
        end)

      json(conn, %{feeds: feeds})
    else
      {:error, :no_org} ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp parse_feed(feed) when feed in @valid_feeds, do: {:ok, String.to_atom(feed)}
  defp parse_feed(_), do: {:error, :invalid_feed}

  defp resolve_org(conn) do
    # Reuse the same token auth as other API controllers: look up the agent
    # from the Bearer token, then return its org_id.
    case conn.assigns[:current_agent] do
      %{organization_id: org_id} when is_binary(org_id) -> {:ok, org_id}
      _ -> {:error, :no_org}
    end
  end
end
