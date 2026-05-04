defmodule KiteAgentHub.Kite.AgentLog do
  @moduledoc """
  In-memory ring-buffer log for per-agent runtime events.

  Each `AgentRunner` tick pushes structured log entries here via
  `AgentLog.push/2`. The dashboard subscribes to the `"agent_log:{id}"`
  PubSub topic and receives real-time updates.

  Entries are stored in an ETS table so they survive across LiveView
  reconnects — a user opening the Logs tab sees the last N events
  immediately without waiting for the next tick.

  ## Storage

  One ETS table (`:agent_log`) shared across all agents. Rows are:
  `{agent_id, [entry, ...]}` where the list is capped at `@max_entries`.
  ETS reads are O(1) lookup + O(N) list copy. Writes are serialized
  through this GenServer to keep the ring-buffer truncation consistent.

  ## Broadcast

  Every `push/2` call also broadcasts `{:agent_log_entry, entry}` on
  `Phoenix.PubSub` topic `"agent_log:{agent_id}"`. LiveView subscribers
  prepend the entry to their local assigns list and stream it without
  needing a round-trip to ETS.

  ## Entry shape

      %{
        agent_id: String.t(),
        level:    :info | :warn | :error | :debug,
        event:    String.t(),    # short machine-readable label
        message:  String.t(),    # human-readable detail
        ts:       DateTime.t()
      }

  ## Supervision

  `AgentLog` is a GenServer started under `KiteAgentHub.Application`.
  Add it before `AgentRunnerSupervisor` in the child spec list.
  """

  use GenServer

  require Logger

  @table :agent_log
  @max_entries 100
  @pubsub KiteAgentHub.PubSub

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Start the AgentLog GenServer (called from Application)."
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Push a log entry for `agent_id`. Appends to the ring buffer and
  broadcasts to the PubSub topic.

  `level` — `:info | :warn | :error | :debug` (default `:info`)
  `event` — short label like `"tick_start"`, `"signal_trade"`, etc.
  `message` — human-readable detail string
  """
  @spec push(String.t(), keyword()) :: :ok
  def push(agent_id, opts) do
    entry = %{
      agent_id: agent_id,
      level: Keyword.get(opts, :level, :info),
      event: Keyword.get(opts, :event, "log"),
      message: Keyword.fetch!(opts, :message),
      ts: DateTime.utc_now()
    }

    GenServer.cast(__MODULE__, {:push, agent_id, entry})
  end

  @doc """
  Return the last `limit` log entries for `agent_id`, newest first.
  Returns `[]` if no entries exist. Non-blocking — reads directly from ETS.
  """
  @spec recent(String.t(), pos_integer()) :: [map()]
  def recent(agent_id, limit \\ @max_entries) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, entries}] -> Enum.take(entries, limit)
      [] -> []
    end
  end

  @doc "Subscribe the calling process to log entries for `agent_id`."
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(agent_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(agent_id))
  end

  @doc "Unsubscribe the calling process from `agent_id` log entries."
  @spec unsubscribe(String.t()) :: :ok
  def unsubscribe(agent_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(agent_id))
  end

  @doc "Clear all stored log entries for `agent_id`."
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    GenServer.cast(__MODULE__, {:clear, agent_id})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:push, agent_id, entry}, state) do
    existing =
      case :ets.lookup(@table, agent_id) do
        [{^agent_id, list}] -> list
        [] -> []
      end

    # Prepend newest entry; trim to ring-buffer cap.
    updated = [entry | existing] |> Enum.take(@max_entries)
    :ets.insert(@table, {agent_id, updated})

    # Broadcast to all dashboard subscribers watching this agent.
    Phoenix.PubSub.broadcast(@pubsub, topic(agent_id), {:agent_log_entry, entry})

    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear, agent_id}, state) do
    :ets.delete(@table, agent_id)
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp topic(agent_id), do: "agent_log:#{agent_id}"
end
