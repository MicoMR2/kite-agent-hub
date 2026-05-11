defmodule KiteAgentHub.Kite.VaultConfig do
  @moduledoc """
  Resolver for the KAH ops-owned vault Passport address.

  The vault is the on-chain identity that receives Rail B (per-trade
  x402 fee) payments from trading agents. Per the CyberSec gate on
  PR-2, the address is loaded from `KAH_VAULT_ADDRESS` at runtime
  (handled in `config/runtime.exs`) and **never committed to the
  repo**. Any later PR that needs to compare an x402 receipt's
  destination against KAH's vault must read through `address/0` —
  not a hardcoded literal.

  Returns `nil` when the env is unset (e.g. dev/test). Callers should
  treat that as "fee accrual disabled" and not crash trade flow.
  """

  @spec address() :: String.t() | nil
  def address do
    Application.get_env(:kite_agent_hub, :kah_vault_address)
  end

  @doc """
  True when the platform has a configured vault address. Useful for
  short-circuiting Rail B (per-trade fee) flows in environments that
  haven't been wired yet.
  """
  @spec configured?() :: boolean()
  def configured? do
    case address() do
      addr when is_binary(addr) and byte_size(addr) > 0 -> true
      _ -> false
    end
  end
end
