defmodule KiteAgentHub.Kite.VaultBalance do
  @moduledoc """
  Server-cached read of the KAH ops vault on-chain balance.

  Public-ledger transparency marker — surfaced on the landing page so
  visitors can verify that fee accrual on Rail B is going to the
  advertised vault address. Read-only against a public chain; no key
  exposure path.

  Backed by the existing `KiteAgentHub.Kite.Blockscout.token_balances/1`
  client (already vetted by previous CyberSec reviews). The vault
  address is sourced exclusively from `VaultConfig.address/0` —
  literals are not permitted in this module or in any template that
  renders the snapshot (CyberSec ask 1, msg 9162).
  """

  alias KiteAgentHub.Kite.Blockscout
  alias KiteAgentHub.Kite.VaultConfig

  @cache_table :kah_vault_balance_cache
  @ttl_seconds 60
  @rpc_timeout_ms 2_000

  @doc """
  Returns `{:ok, snapshot}` when a fresh-or-still-warm reading is
  available, `{:error, :unconfigured}` when the vault env is unset
  (e.g. dev/test), or `{:error, reason}` when the underlying
  Blockscout call has failed and there is no last-good snapshot to
  serve.

  Snapshot shape:

      %{
        address: "0x...",
        usdc: Decimal | nil,
        usdt: Decimal | nil,
        native_kite: Decimal | nil,
        fetched_at: ~U[...]
      }

  Per CyberSec ask 2 (msg 9162), this function is wrapped in a
  bounded `Task.async` with a 2s timeout when the controller / LV
  uses it through `cached_or_fetch/0` — neither the LV mount nor the
  controller render path may block on Blockscout.
  """
  @spec cached() ::
          {:ok, map()} | {:error, :unconfigured | term()}
  def cached do
    ensure_table()

    case VaultConfig.address() do
      addr when is_binary(addr) and addr != "" ->
        now = System.system_time(:second)
        case :ets.lookup(@cache_table, :snapshot) do
          [{:snapshot, %{fetched_at_unix: ts} = snap}] when now - ts < @ttl_seconds ->
            {:ok, sanitize(snap)}

          _ ->
            refresh(addr)
        end

      _ ->
        {:error, :unconfigured}
    end
  end

  @doc """
  Same as `cached/0` but bounded by a Task.async + timeout. Use this
  on hot render paths (LiveView mount, page controller action) where
  a Blockscout outage must not block or crash the response.

  Returns the same shape as `cached/0` plus `{:error, :timeout}` if
  the underlying fetch did not return within `@rpc_timeout_ms`.
  """
  @spec cached_or_fetch() ::
          {:ok, map()} | {:error, :unconfigured | :timeout | term()}
  def cached_or_fetch do
    task = Task.async(fn -> cached() end)

    case Task.yield(task, @rpc_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :timeout}
    end
  end

  ## Internals

  defp refresh(address) do
    case Blockscout.token_balances(address) do
      {:ok, balances} when is_list(balances) ->
        snap = %{
          address: address,
          usdc: extract(balances, "USDC"),
          usdt: extract(balances, "USDT"),
          native_kite: extract(balances, "KITE"),
          fetched_at: DateTime.utc_now() |> DateTime.truncate(:second),
          fetched_at_unix: System.system_time(:second)
        }

        :ets.insert(@cache_table, {:snapshot, snap})
        {:ok, sanitize(snap)}

      err ->
        # Last-good fallback: if a previous successful read is still
        # in the cache, return it — a transient Blockscout outage
        # should not flip the badge to em-dash. The cached row keeps
        # its original `fetched_at` so the UI can show a staleness
        # hint.
        case :ets.lookup(@cache_table, :snapshot) do
          [{:snapshot, snap}] -> {:ok, sanitize(snap)}
          _ -> {:error, err_reason(err)}
        end
    end
  end

  # Symbol-allowlist parse (CyberSec ask 4, msg 9162) — Blockscout
  # rows for tokens outside USDC/USDT/KITE are dropped on the floor.
  # The full Blockscout response is never put into assigns.
  defp extract(balances, symbol) do
    Enum.find_value(balances, fn b ->
      if String.upcase(to_string(b[:symbol] || "")) == symbol do
        format_balance(b[:balance], b[:decimals] || 18)
      end
    end)
  end

  defp format_balance(value, decimals) when is_binary(value) and is_integer(decimals) do
    case Decimal.parse(value) do
      {dec, ""} -> Decimal.div(dec, decimal_pow10(decimals))
      _ -> nil
    end
  end

  defp format_balance(_, _), do: nil

  defp decimal_pow10(0), do: Decimal.new(1)
  defp decimal_pow10(n) when n > 0, do: Decimal.mult(Decimal.new(10), decimal_pow10(n - 1))
  defp decimal_pow10(_), do: Decimal.new(1)

  defp sanitize(snap), do: Map.drop(snap, [:fetched_at_unix])

  defp err_reason({:error, r}), do: r
  defp err_reason(other), do: other

  # Race-safe ETS init (CyberSec ask 3, msg 9162). Concurrent first
  # readers may both attempt :ets.new — the second one will hit
  # ArgumentError, which we treat as "already exists, fine".
  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end
end
