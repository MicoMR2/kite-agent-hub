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

  @doc """
  Allowlist of chain ids accepted on the user-driven mutation path
  (CyberSec ask 1, msg 9212). The new-row default fill still uses
  `default/0`, but a user changing chain via the agent settings UI
  must pass one of these explicit values.
  """
  @spec valid_chain_ids() :: [integer()]
  def valid_chain_ids, do: [@testnet, @mainnet]

  @doc "Convenience accessor for the testnet chain id constant."
  @spec testnet() :: integer()
  def testnet, do: @testnet

  @doc "Convenience accessor for the mainnet chain id constant."
  @spec mainnet() :: integer()
  def mainnet, do: @mainnet

  @doc """
  Whether the mainnet signing key is configured on this instance.
  Returns boolean only — never the key value itself (CyberSec ask 2,
  msg 9212). Gates the user-driven testnet→mainnet flip in
  `AgentsLive.handle_event("select_chain", …)` before any
  `Repo.update` runs.
  """
  @spec mainnet_available?() :: boolean()
  def mainnet_available? do
    case Application.get_env(:kite_agent_hub, :agent_private_key_mainnet) ||
           System.get_env("AGENT_PRIVATE_KEY_MAINNET") do
      v when is_binary(v) and byte_size(v) > 0 -> true
      _ -> false
    end
  end
end
