defmodule KiteAgentHub.Api.RateLimiter do
  @moduledoc """
  Per-agent token-bucket rate limiter for the public trade API.

  Keyed on `agent.id`, enforces a cap per one-second window:

      iex> RateLimiter.check(agent.id)
      :ok       # under the cap
      {:error, :rate_limited}  # over the cap

  **Node-local:** Fly runs two machines; each has its own ETS table,
  so the cap is enforced per-node, not globally. That is acceptable
  for the hackathon deployment — a determined attacker can sustain
  up to `2 * @max_per_second` by hitting both machines, but normal
  clients hit one node and see the documented limit. Upgrade to
  `Hammer` (Redis/Mnesia backend) when true global limits are
  needed.

  Table lifecycle: initialized in `init/1` at boot, not lazy on
  first request — prevents a race where two requests race to
  create the table.
  """

  use GenServer

  @table :kah_api_rate_limiter
  @max_per_second 10
  @window_ms 1_000

  # ── Client API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `:ok` if the agent is under the per-second cap, or
  `{:error, :rate_limited}` otherwise. Must be called after
  `start_link/1` has completed; the table is created in `init/1`.
  """
  @spec check(String.t()) :: :ok | {:error, :rate_limited}
  def check(agent_id) when is_binary(agent_id) do
    bucket = System.system_time(:millisecond) |> div(@window_ms)
    key = {agent_id, bucket}
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count > @max_per_second do
      {:error, :rate_limited}
    else
      :ok
    end
  rescue
    ArgumentError ->
      # Table missing (pre-boot or crash). Fail open rather than
      # block trade submission — CyberSec requirement: billing/rate
      # observation must not become a service-availability risk.
      :ok
  end

  # ── Server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    # Periodically sweep old buckets so the table does not grow
    # unbounded. Buckets older than 5 seconds are safe to drop.
    schedule_sweep()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    now_bucket = System.system_time(:millisecond) |> div(@window_ms)
    cutoff = now_bucket - 5

    :ets.select_delete(@table, [
      {{{:_, :"$1"}, :_}, [{:<, :"$1", cutoff}], [true]}
    ])

    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, 5_000)
  end
end
