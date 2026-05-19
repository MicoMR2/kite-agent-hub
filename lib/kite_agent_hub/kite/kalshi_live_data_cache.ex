defmodule KiteAgentHub.Kite.KalshiLiveDataCache do
  @moduledoc """
  ETS-backed cache for Kalshi live event-truth data (PR-I₂).
  Live data updates fast (every few seconds during a live event);
  persisting every reading would burn DB I/O for no replay value
  — the live-data is ephemeral by definition. Cache lives in a
  named public ETS table started under the supervision tree.

  Reads are O(1) and lock-free. Entries auto-expire on read past
  their TTL (default 30s) — no separate sweeper process needed at
  this volume. The cache fills only for tickers with open KAH
  positions (driven by `KalshiLiveDataWorker`); orphaned entries
  age out naturally.
  """

  use GenServer

  @table :kalshi_live_data_cache
  # TTL 90s paired with 60s cron leaves a 30s overlap buffer rather
  # than a 30s gap — CyberSec 10763 ③ + Phorari 10764 reversal.
  # 90s of staleness is fine for live event-truth semantics (sports
  # scores / election counts / weather thresholds — none change
  # faster than that in ways our scorer reacts to).
  @default_ttl_seconds 90

  # ── Client API ────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Cache a parsed live-data entry keyed by ticker. `value` is the
  full parsed map from `KalshiClient.parse_live_data/3` (or any
  caller-shaped map; the cache doesn't inspect it).
  """
  def put(ticker, value) when is_binary(ticker) and is_map(value) do
    expires_at = System.monotonic_time(:second) + @default_ttl_seconds
    safe_insert({ticker, value, expires_at})
    :ok
  end

  def put(_ticker, _value), do: :ok

  @doc """
  Fetch a cached entry. Returns `{:ok, value}` when present and
  unexpired, `:miss` when absent or stale (stale entries get
  deleted on read so the table doesn't accumulate junk). Wrapped
  in try/rescue so a cold-start / restart race where the table
  isn't created yet returns `:miss` instead of crashing the
  scoring caller (CyberSec ① msg 10760).
  """
  def get(ticker) when is_binary(ticker) do
    now = System.monotonic_time(:second)

    case safe_lookup(ticker) do
      [{^ticker, value, expires_at}] when expires_at >= now ->
        {:ok, value}

      [{^ticker, _, _}] ->
        _ = safe_delete(ticker)
        :miss

      _ ->
        :miss
    end
  end

  def get(_ticker), do: :miss

  defp safe_lookup(ticker) do
    :ets.lookup(@table, ticker)
  rescue
    ArgumentError -> []
  end

  defp safe_insert(row) do
    :ets.insert(@table, row)
  rescue
    ArgumentError -> false
  end

  defp safe_delete(ticker) do
    :ets.delete(@table, ticker)
  rescue
    ArgumentError -> false
  end

  @doc "Drop everything. Used in tests."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc false
  def table_name, do: @table

  # ── Server ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
