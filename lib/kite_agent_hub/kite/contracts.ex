defmodule KiteAgentHub.Kite.Contracts do
  @moduledoc """
  Compile-time pinned on-chain identifiers for Kite testnet (2368)
  and mainnet (2366).

  CyberSec ask 1 at msg 9264: every value in this module is a
  module-attribute literal so a runtime envvar swap cannot redirect
  mainnet calls to attacker-controlled endpoints or token contracts.
  The only piece of chain-specific state that is NOT pinned at
  compile time is the platform attestation treasury address — that's
  operational ops state (per-chain ops wallet), so it stays a Fly
  secret (`KITE_TREASURY_ADDRESS` / `KITE_TREASURY_ADDRESS_MAINNET`).
  See `treasury_address/1`.

  All addresses are downcased at the source so allowlist comparisons
  against Blockscout-returned values can normalize via
  `String.downcase/1` on both sides (CyberSec ask 6).
  """

  @testnet_rpc "https://rpc-testnet.gokite.ai/"
  @mainnet_rpc "https://rpc.gokite.ai/"

  @testnet_explorer "https://testnet.kitescan.ai"
  @mainnet_explorer "https://kitescan.ai"

  @gasless_relayer_base "https://gasless.gokite.ai"

  # Testnet KITE was deployed as an ERC-20 for the demo period.
  @testnet_kite_erc20 "0x0ff5393387ad2f9f691fd6fd28e07e3969e27e63"

  # Mainnet KITE is the NATIVE coin (no ERC-20 contract). Wrapped
  # KITE (WKITE) ERC-20 exists for protocols that need a token
  # interface and shows up in token_balances results.
  @wkite_mainnet "0xcc788dc0486cd2baacff287eea1902cc09fba570"

  @usdc_e_mainnet "0x7ab6f3ed87c42ef0adb67ed95090f8bf5240149e"
  @usdt_mainnet "0x3fdd283c4c43a60398bf93ca01a8a8bd773a755b"

  # Chain id literals — duplicated from KiteAgentHub.Kite.ChainId so the
  # @module_attr in the pattern-match heads below is a true compile-time
  # constant rather than a function call. CyberSec ask 1 (msg 9264).
  @testnet_id 2368
  @mainnet_id 2366

  @doc """
  RPC URL for the given chain id. Hardcoded allowlist (CyberSec
  ask 3) — no env override, no user-controlled input.
  """
  @spec rpc_url(integer()) :: String.t()
  def rpc_url(@testnet_id), do: @testnet_rpc
  def rpc_url(@mainnet_id), do: @mainnet_rpc

  @doc """
  Blockscout / Kitescan explorer base URL for the given chain id.
  """
  @spec explorer_url(integer()) :: String.t()
  def explorer_url(@testnet_id), do: @testnet_explorer
  def explorer_url(@mainnet_id), do: @mainnet_explorer

  @doc """
  Gasless relayer URL for the given chain id. Wraps the unified
  service endpoint with the `/testnet` or `/mainnet` path segment.
  """
  @spec gasless_relayer_url(integer()) :: String.t()
  def gasless_relayer_url(@testnet_id), do: @gasless_relayer_base <> "/testnet"
  def gasless_relayer_url(@mainnet_id), do: @gasless_relayer_base <> "/mainnet"

  @doc """
  Tokens this platform recognizes for the given chain id. Each entry
  is `{symbol, address_downcased, decimals}`. Used by `vault_balance.ex`
  as the allowlist for Blockscout-returned token rows (CyberSec
  ask 7). KITE on mainnet is the native coin and is NOT in this map
  — query it separately via `eth_getBalance`.
  """
  @spec allowed_tokens(integer()) :: [{String.t(), String.t(), non_neg_integer()}]
  def allowed_tokens(@testnet_id) do
    [
      {"KITE", @testnet_kite_erc20, 18},
      {"USDC.e", @usdc_e_mainnet, 6},
      {"USDT", @usdt_mainnet, 6}
    ]
  end

  def allowed_tokens(@mainnet_id) do
    [
      {"WKITE", @wkite_mainnet, 18},
      {"USDC.e", @usdc_e_mainnet, 6},
      {"USDT", @usdt_mainnet, 6}
    ]
  end

  @doc """
  Whether the chain id treats KITE as the native coin (eth_getBalance)
  rather than an ERC-20. Only mainnet returns true.
  """
  @spec native_kite?(integer()) :: boolean()
  def native_kite?(@mainnet_id), do: true
  def native_kite?(_), do: false

  @doc """
  Operational treasury address for the given chain id. Reads from
  the Fly secrets indexed by chain — `KITE_TREASURY_ADDRESS` for
  testnet, `KITE_TREASURY_ADDRESS_MAINNET` for mainnet. Returns
  `{:error, :mainnet_treasury_unconfigured}` when mainnet is asked
  for but the secret is unset; NO fallback to the testnet address
  (CyberSec ask 2, hard gate).
  """
  @spec treasury_address(integer()) ::
          {:ok, String.t()} | {:error, :mainnet_treasury_unconfigured | :unknown_chain}
  def treasury_address(@testnet_id) do
    case System.get_env("KITE_TREASURY_ADDRESS") ||
           Application.get_env(:kite_agent_hub, :kite_treasury_address) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :testnet_treasury_unconfigured}
    end
  end

  def treasury_address(@mainnet_id) do
    case System.get_env("KITE_TREASURY_ADDRESS_MAINNET") ||
           Application.get_env(:kite_agent_hub, :kite_treasury_address_mainnet) do
      v when is_binary(v) and byte_size(v) > 0 -> {:ok, v}
      _ -> {:error, :mainnet_treasury_unconfigured}
    end
  end

  def treasury_address(_), do: {:error, :unknown_chain}
end
