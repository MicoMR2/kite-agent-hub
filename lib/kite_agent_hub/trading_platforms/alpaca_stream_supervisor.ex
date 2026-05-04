defmodule KiteAgentHub.TradingPlatforms.AlpacaStreamSupervisor do
  @moduledoc """
  Dynamic supervisor for `AlpacaStream` GenServers.

  Manages one child per active feed (`:stocks`, `:crypto`, `:news`).
  Feeds are started on demand by calling `start_feed/3` — the app boots
  without any active streams and only connects when an org with Alpaca
  credentials is available.

  ## Usage

      # Start the stocks feed for an org with default equity watchlist:
      AlpacaStreamSupervisor.start_feed(:stocks, "org-uuid", symbols: ~w(AAPL SPY QQQ MSFT))

      # Start the crypto feed:
      AlpacaStreamSupervisor.start_feed(:crypto, "org-uuid", symbols: ~w(BTC/USD ETH/USD))

      # Start the news feed (all news):
      AlpacaStreamSupervisor.start_feed(:news, "org-uuid", symbols: ["*"])

      # Stop a feed:
      AlpacaStreamSupervisor.stop_feed(:stocks)

  The supervisor is added to the Application child list in `application.ex`.
  Feeds restart with `:transient` strategy — they recover from crashes but
  not from a clean `:stop` (the reconnection loop in `AlpacaStream` handles
  WebSocket-level disconnects without crashing the GenServer).
  """

  use DynamicSupervisor

  alias KiteAgentHub.TradingPlatforms.AlpacaStream

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a streaming feed for `org_id`. Returns `{:ok, pid}` or
  `{:error, {:already_started, pid}}` if that feed is already running.

  ## Options
    * `:symbols` — list of ticker symbols to subscribe to
    * `:topics`  — for stocks/crypto: `["trades", "quotes", "bars"]`
                   (default: `["trades", "quotes"]`)
  """
  @spec start_feed(atom(), String.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_feed(feed, org_id, opts \\ []) do
    child_spec =
      {AlpacaStream,
       [
         feed: feed,
         org_id: org_id,
         symbols: Keyword.get(opts, :symbols, []),
         topics: Keyword.get(opts, :topics, ["trades", "quotes"])
       ]}

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc "Stop a running feed by feed atom. Returns :ok or {:error, :not_found}."
  @spec stop_feed(atom()) :: :ok | {:error, :not_found}
  def stop_feed(feed) do
    case AlpacaStream.status(feed) do
      :not_started ->
        {:error, :not_found}

      _ ->
        pid = GenServer.whereis(via(feed))
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  @doc "List all currently running feed atoms."
  @spec running_feeds() :: [atom()]
  def running_feeds do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn {_, pid, _, _} ->
      case Registry.keys(KiteAgentHub.AgentRegistry, pid) do
        [{AlpacaStream, feed}] -> [feed]
        _ -> []
      end
    end)
  end

  defp via(feed), do: {:via, Registry, {KiteAgentHub.AgentRegistry, {AlpacaStream, feed}}}
end
