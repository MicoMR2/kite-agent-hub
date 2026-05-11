defmodule KiteAgentHub.Kite.ChainId do
  @moduledoc """
  Central resolver for the Kite chain id. Operators flip the platform's
  default chain by setting `KITE_CHAIN_ID` (handled in `config/runtime.exs`);
  callers read `default/0` instead of hardcoding integers.

  This module does NOT replace the routing constants in modules that
  intentionally dispatch between testnet and mainnet (e.g.
  `KiteAttestationWorker`, `GaslessClient` `@tokens` map, `TxSigner`'s
  testnet utility constant). It only stands in for the fallback used when
  a fresh row is inserted or an agent row carries a nil `chain_id`.
  """

  @testnet 2368
  @mainnet 2366

  @doc """
  Returns the configured platform-default chain id. Falls back to Kite
  testnet (2368) when the app env is unset, so dev/test environments
  don't need to declare it.
  """
  @spec default() :: integer()
  def default do
    Application.get_env(:kite_agent_hub, :kite_chain_id, @testnet)
  end

  @doc """
  Human-readable label for the configured chain id, used in UI pills and
  email subject/footer chrome.

  Returns `"Testnet · 2368"`, `"Mainnet · 2366"`, or `"Chain · N"` for any
  other value an operator might wire in (e.g. a custom devnet).
  """
  @spec label(integer() | nil) :: String.t()
  def label(chain_id \\ default())

  def label(@testnet), do: "Testnet · #{@testnet}"
  def label(@mainnet), do: "Mainnet · #{@mainnet}"
  def label(n) when is_integer(n), do: "Chain · #{n}"
  def label(_), do: label(@testnet)
end
