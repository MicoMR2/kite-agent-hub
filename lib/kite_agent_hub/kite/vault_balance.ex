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

  alias KiteAgentHub.Kite.{Blockscout, ChainId, Contracts, VaultConfig}

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
    # CyberSec ask 4 (msg 9264): chain_id is selected ONCE at the top
    # of the refresh path; both the Blockscout URL and the symbol
    # allowlist are pinned to this value for the duration of the call.
    chain_id = ChainId.default()
    allowed = Contracts.allowed_tokens(chain_id)

    case Blockscout.token_balances(address, chain_id) do
      {:ok, balances} when is_list(balances) ->
        snap = %{
          address: address,
          chain_id: chain_id,
          usdc: extract(balances, "USDC.e", allowed),
          usdt: extract(balances, "USDT", allowed),
          native_kite: native_kite_balance(address, chain_id, balances, allowed),
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

  # On mainnet, KITE is the native coin — query the address balance
  # endpoint (coin_balance) rather than token_balances. On testnet,
  # KITE is the ERC-20 at the testnet contract address.
  defp native_kite_balance(address, chain_id, balances, allowed) do
    if Contracts.native_kite?(chain_id) do
      case Blockscout.address_info(address, chain_id) do
        {:ok, %{balance_wei: wei}} -> format_balance(wei, 18)
        _ -> nil
      end
    else
      extract(balances, "KITE", allowed)
    end
  end

  # Symbol + contract-address allowlist parse (CyberSec asks 6+7,
  # msg 9264). Blockscout rows are matched on both `symbol` AND
  # `token.address` against the chain-specific allowlist from
  # `Contracts.allowed_tokens/1`; address comparison normalizes both
  # sides via `String.downcase/1` so an EIP-55 checksum mismatch
  # can't silently bypass the gate.
  defp extract(balances, symbol, allowed) do
    Enum.find_value(balances, fn b ->
      b_symbol = String.upcase(to_string(b[:symbol] || ""))
      b_addr = (b[:contract_address] || b[:address] || "") |> to_string() |> String.downcase()
      target_symbol = String.upcase(symbol)

      with true <- b_symbol == target_symbol,
           {_sym, allowed_addr, decimals} <-
             Enum.find(allowed, fn {sym, addr, _d} ->
               String.upcase(sym) == target_symbol and b_addr == addr
             end) do
        _ = allowed_addr
        format_balance(b[:balance], b[:decimals] || decimals)
      else
        _ -> nil
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

  defp sanitize(snap) do
    snap
    |> Map.drop([:fetched_at_unix])
    |> Map.put_new(:chain_id, ChainId.default())
  end

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
