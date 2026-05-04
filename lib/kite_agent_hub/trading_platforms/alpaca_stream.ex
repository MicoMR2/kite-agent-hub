defmodule KiteAgentHub.TradingPlatforms.AlpacaStream do
  @moduledoc """
  Real-time Alpaca market-data WebSocket client.

  Maintains a persistent WebSocket connection to Alpaca's streaming data
  endpoints and broadcasts incoming tick events to Phoenix PubSub so any
  subscribed process (LiveViews, AgentRunners, signal engines) can react
  to market data without polling.

  Built on top of `WebSockex`, which handles the upgrade handshake,
  frame encoding/decoding, and basic reconnect-on-disconnect lifecycle.

  ## Supported feeds

  | Feed     | URL                                                          |
  |----------|--------------------------------------------------------------|
  | `:stocks`| wss://stream.data.alpaca.markets/v2/iex                      |
  | `:crypto`| wss://stream.data.alpaca.markets/v1beta3/crypto/us           |
  | `:news`  | wss://stream.data.alpaca.markets/v1beta1/news                |

  ## Connection state machine

  1. `init/1`             — capture feed/org/symbols/topics, no connection yet.
  2. `handle_connect/2`   — send the auth frame `{action: auth, key, secret}`.
  3. On `{T: success, msg: authenticated}` — send the subscribe frame.
  4. On any other `{T: ...}` event — `dispatch_message` decodes the tick and
     broadcasts via `Phoenix.PubSub`.
  5. On `{T: error, code: 402}` — log + stop (auth failed, no point reconnecting).
  6. On `handle_disconnect/2` — `{:reconnect, state}` so WebSockex re-opens.

  ## Topics

      "alpaca_stream:{feed}:{symbol}"   # one per (feed, symbol)
      "alpaca_stream:news:ALL"          # all news regardless of symbol

  Subscribe with `KiteAgentHub.TradingPlatforms.AlpacaStream.subscribe/2`.
  """

  use WebSockex

  require Logger

  alias KiteAgentHub.Credentials

  @pubsub KiteAgentHub.PubSub

  @feed_urls %{
    stocks: "wss://stream.data.alpaca.markets/v2/iex",
    crypto: "wss://stream.data.alpaca.markets/v1beta3/crypto/us",
    news: "wss://stream.data.alpaca.markets/v1beta1/news"
  }

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc """
  Start an AlpacaStream WebSockex client for one feed.

  ## Options
    * `:feed`    — `:stocks | :crypto | :news` (required)
    * `:org_id`  — organisation whose Alpaca credentials to use (required)
    * `:symbols` — list of symbols to subscribe to (e.g. `["AAPL", "SPY"]`).
                   For `:news` this filters by symbol; pass `["*"]` for all news.
    * `:topics`  — for stocks/crypto: list of `["trades", "quotes", "bars"]`.
                   Defaults to `["trades", "quotes"]`.
  """
  def start_link(opts) do
    feed = Keyword.fetch!(opts, :feed)
    org_id = Keyword.fetch!(opts, :org_id)

    case Credentials.fetch_secret(org_id, :alpaca) do
      {:ok, {key_id, secret}} ->
        url = Map.fetch!(@feed_urls, feed)

        state = %{
          feed: feed,
          org_id: org_id,
          symbols: Keyword.get(opts, :symbols, []),
          topics: Keyword.get(opts, :topics, ["trades", "quotes"]),
          key_id: key_id,
          secret: secret,
          status: :connecting
        }

        WebSockex.start_link(url, __MODULE__, state, name: name(feed))

      _ ->
        Logger.warning(
          "AlpacaStream(#{feed}): Alpaca credentials not configured for org #{org_id}"
        )

        {:error, :not_configured}
    end
  end

  @doc "Subscribe the calling process to ticks for a (feed, symbol) pair."
  def subscribe(feed, symbol) do
    Phoenix.PubSub.subscribe(@pubsub, topic(feed, symbol))
  end

  @doc "Dynamically add symbols to the active subscription."
  def add_symbols(feed, symbols) when is_list(symbols) do
    case GenServer.whereis(name(feed)) do
      nil -> {:error, :not_started}
      pid -> WebSockex.cast(pid, {:add_symbols, symbols})
    end
  end

  @doc "Dynamically remove symbols from the active subscription."
  def remove_symbols(feed, symbols) when is_list(symbols) do
    case GenServer.whereis(name(feed)) do
      nil -> {:error, :not_started}
      pid -> WebSockex.cast(pid, {:remove_symbols, symbols})
    end
  end

  @doc "Return the current connection status for a feed."
  def status(feed) do
    case GenServer.whereis(name(feed)) do
      nil ->
        :not_started

      pid ->
        WebSockex.cast(pid, {:status, self()})
        # Async — caller blocks on a receive if they want the value.
    end
  end

  # ── WebSockex callbacks ───────────────────────────────────────────────────────

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("AlpacaStream(#{state.feed}): WebSocket connected — sending auth")

    # WebSockex won't let us return a frame from handle_connect directly,
    # so push the auth frame asynchronously via cast-to-self.
    WebSockex.cast(self(), :send_auth)
    {:ok, %{state | status: :authenticating}}
  end

  @impl true
  def handle_disconnect(disconnect_map, state) do
    Logger.info("AlpacaStream(#{state.feed}): disconnected — #{inspect(disconnect_map.reason)}")

    case state.status do
      :auth_failed ->
        # Bad credentials — no point reconnecting in a tight loop.
        {:ok, state}

      _ ->
        # Default: WebSockex's automatic reconnect (no backoff configurable
        # at this layer; if Alpaca rate-limits us we'd need to add a sleep
        # here). For most transient disconnects, immediate reconnect is fine.
        {:reconnect, %{state | status: :reconnecting}}
    end
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, list} when is_list(list) ->
        # Alpaca often batches multiple events in one frame.
        Enum.reduce(list, {:ok, state}, fn msg, {:ok, st} ->
          dispatch(msg, st)
        end)

      {:ok, msg} when is_map(msg) ->
        dispatch(msg, state)

      {:error, _} ->
        Logger.debug("AlpacaStream(#{state.feed}): could not decode frame: #{inspect(payload)}")

        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast(:send_auth, state) do
    body =
      Jason.encode!(%{"action" => "auth", "key" => state.key_id, "secret" => state.secret})

    {:reply, {:text, body}, state}
  end

  def handle_cast({:send_subscribe, symbols, topics}, state) do
    body = subscribe_body(state.feed, symbols, topics)
    {:reply, {:text, Jason.encode!(body)}, state}
  end

  def handle_cast({:send_unsubscribe, symbols, topics}, state) do
    body = unsubscribe_body(state.feed, symbols, topics)
    {:reply, {:text, Jason.encode!(body)}, state}
  end

  def handle_cast({:add_symbols, symbols}, state) do
    new_symbols = Enum.uniq(state.symbols ++ symbols)

    if state.status == :subscribed do
      {:reply, {:text, Jason.encode!(subscribe_body(state.feed, symbols, state.topics))},
       %{state | symbols: new_symbols}}
    else
      # Not yet subscribed — just stash and the post-auth subscribe will pick them up.
      {:ok, %{state | symbols: new_symbols}}
    end
  end

  def handle_cast({:remove_symbols, symbols}, state) do
    new_symbols = state.symbols -- symbols

    if state.status == :subscribed and symbols != [] do
      {:reply, {:text, Jason.encode!(unsubscribe_body(state.feed, symbols, state.topics))},
       %{state | symbols: new_symbols}}
    else
      {:ok, %{state | symbols: new_symbols}}
    end
  end

  def handle_cast({:status, from_pid}, state) do
    send(from_pid, {:alpaca_stream_status, state.feed, state.status})
    {:ok, state}
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  # Returns one of WebSockex.handle_frame/2's accepted return shapes:
  # `{:ok, state}` to continue, or `{:reply, frame, state}` to send a frame.
  defp dispatch(%{"T" => "success", "msg" => "connected"}, state) do
    Logger.debug("AlpacaStream(#{state.feed}): server greeted with 'connected'")
    {:ok, state}
  end

  defp dispatch(%{"T" => "success", "msg" => "authenticated"}, state) do
    Logger.info(
      "AlpacaStream(#{state.feed}): authenticated — subscribing to #{inspect(state.symbols)}"
    )

    cond do
      state.symbols == [] ->
        {:ok, %{state | status: :authenticated}}

      true ->
        body = subscribe_body(state.feed, state.symbols, state.topics)

        {:reply, {:text, Jason.encode!(body)}, %{state | status: :subscribed}}
    end
  end

  defp dispatch(%{"T" => "error", "code" => 402} = msg, state) do
    Logger.error("AlpacaStream(#{state.feed}): auth failed — #{inspect(msg)}")
    # Mark so handle_disconnect does not re-open in a loop.
    {:ok, %{state | status: :auth_failed}}
  end

  defp dispatch(%{"T" => "subscription"} = msg, state) do
    Logger.debug("AlpacaStream(#{state.feed}): subscription confirmed: #{inspect(msg)}")
    {:ok, state}
  end

  defp dispatch(%{"T" => "t"} = msg, %{feed: feed} = state) do
    broadcast(feed, msg["S"], %{
      type: "t",
      symbol: msg["S"],
      price: msg["p"],
      size: msg["s"],
      ts: msg["t"]
    })

    {:ok, state}
  end

  defp dispatch(%{"T" => "q"} = msg, %{feed: feed} = state) do
    broadcast(feed, msg["S"], %{
      type: "q",
      symbol: msg["S"],
      bid: msg["bp"],
      bid_size: msg["bs"],
      ask: msg["ap"],
      ask_size: msg["as"],
      ts: msg["t"]
    })

    {:ok, state}
  end

  defp dispatch(%{"T" => "b"} = msg, %{feed: feed} = state) do
    broadcast(feed, msg["S"], %{
      type: "b",
      symbol: msg["S"],
      open: msg["o"],
      high: msg["h"],
      low: msg["l"],
      close: msg["c"],
      volume: msg["v"],
      ts: msg["t"]
    })

    {:ok, state}
  end

  defp dispatch(%{"T" => "n"} = msg, %{feed: :news} = state) do
    event = %{
      type: "n",
      id: msg["id"],
      symbols: msg["symbols"],
      headline: msg["headline"],
      summary: msg["summary"],
      author: msg["author"],
      created_at: msg["created_at"],
      url: msg["url"]
    }

    broadcast(:news, "ALL", event)
    Enum.each(event.symbols || [], fn sym -> broadcast(:news, sym, event) end)
    {:ok, state}
  end

  defp dispatch(_msg, state), do: {:ok, state}

  # ── Frame body builders ──────────────────────────────────────────────────────

  defp subscribe_body(:news, symbols, _topics) do
    %{"action" => "subscribe", "news" => normalize_news_symbols(symbols)}
  end

  defp subscribe_body(_feed, symbols, topics) do
    topics
    |> Map.new(fn t -> {t, symbols} end)
    |> Map.put("action", "subscribe")
  end

  defp unsubscribe_body(:news, symbols, _topics) do
    %{"action" => "unsubscribe", "news" => symbols}
  end

  defp unsubscribe_body(_feed, symbols, topics) do
    topics
    |> Map.new(fn t -> {t, symbols} end)
    |> Map.put("action", "unsubscribe")
  end

  # `["*"]` is the Alpaca convention for "subscribe to all news"; pass it
  # through. Anything else (including an empty list) becomes `["*"]` so the
  # subscribe call is never a no-op.
  defp normalize_news_symbols([]), do: ["*"]
  defp normalize_news_symbols(["*"]), do: ["*"]
  defp normalize_news_symbols(other), do: other

  # ── Broadcast / topic helpers ────────────────────────────────────────────────

  defp broadcast(feed, symbol, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(feed, symbol), event)
  end

  @doc false
  def topic(feed, symbol), do: "alpaca_stream:#{feed}:#{symbol}"

  defp name(feed), do: {:via, Registry, {KiteAgentHub.AgentRegistry, {__MODULE__, feed}}}
end
