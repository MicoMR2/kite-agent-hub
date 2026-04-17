defmodule KiteAgentHub.Kite.RPC do
  @moduledoc """
  Direct EVM JSON-RPC client for Kite chain. No SDK required.
  Uses standard eth_* calls over HTTP POST via Req.

  Kite Testnet : https://rpc-testnet.gokite.ai/ (chain 2368)
  Kite Mainnet : https://rpc.gokite.ai/          (chain 2366)
  Explorer     : https://testnet.kitescan.ai/
  """

  @testnet_rpc "https://rpc-testnet.gokite.ai/"
  @mainnet_rpc "https://rpc.gokite.ai/"

  # ── Public API ────────────────────────────────────────────────────────────────

  @doc "Get native KITE balance for an address (returns wei as integer)."
  def get_balance(address, chain \\ :testnet) do
    call("eth_getBalance", [address, "latest"], chain)
    |> decode_hex_integer()
  end

  @doc "Get the latest block number."
  def block_number(chain \\ :testnet) do
    call("eth_blockNumber", [], chain)
    |> decode_hex_integer()
  end

  @doc "Call a read-only contract function (eth_call)."
  def eth_call(to, data, chain \\ :testnet) do
    call("eth_call", [%{to: to, data: data}, "latest"], chain)
  end

  @doc "Get transaction receipt by hash."
  def get_transaction_receipt(tx_hash, chain \\ :testnet) do
    call("eth_getTransactionReceipt", [tx_hash], chain)
  end

  @doc """
  Get transaction count (nonce) for an address.

  Uses the `"pending"` block tag so the returned nonce includes
  transactions already submitted to the mempool but not yet mined.
  Using `"latest"` would let two jobs that run in quick succession
  fetch the same nonce before the first tx confirms, causing them
  to sign byte-identical value transfers and produce duplicate tx
  hashes on the chain side.
  """
  def get_transaction_count(address, chain \\ :testnet) do
    call("eth_getTransactionCount", [address, "pending"], chain)
    |> decode_hex_integer()
  end

  @doc "Get current gas price in wei."
  def gas_price(chain \\ :testnet) do
    call("eth_gasPrice", [], chain)
    |> decode_hex_integer()
  end

  @doc "Send a raw signed transaction. Returns {:ok, tx_hash} or {:error, reason}."
  def send_raw_transaction(signed_tx_hex, chain \\ :testnet) do
    call("eth_sendRawTransaction", [signed_tx_hex], chain)
  end

  @doc "Estimate gas for a transaction."
  def estimate_gas(tx_params, chain \\ :testnet) do
    call("eth_estimateGas", [tx_params], chain)
    |> decode_hex_integer()
  end

  @doc "Get current chain ID."
  def chain_id(chain \\ :testnet) do
    call("eth_chainId", [], chain)
    |> decode_hex_integer()
  end

  # ── Vault read helpers (ABI-encoded calls) ────────────────────────────────────

  @doc "Read vaultBalance() from TradingAgentVault."
  def vault_balance(vault_address, chain \\ :testnet) do
    # vaultBalance() selector: keccak256("vaultBalance()")[0..3] = 0x8fa1f67f
    data = "0x8fa1f67f"

    with {:ok, result} <- eth_call(vault_address, data, chain) do
      {:ok, decode_hex_integer({:ok, result})}
    end
  end

  @doc "Read idleBalance() from TradingAgentVault."
  def idle_balance(vault_address, chain \\ :testnet) do
    # idleBalance() selector: 0x2b2a7f4c
    data = "0x2b2a7f4c"

    with {:ok, result} <- eth_call(vault_address, data, chain) do
      {:ok, decode_hex_integer({:ok, result})}
    end
  end

  @doc "Check if trading is halted on the vault."
  def halt_trading?(vault_address, chain \\ :testnet) do
    # haltTrading() selector: 0x10f41d5e
    data = "0x10f41d5e"

    with {:ok, result} <- eth_call(vault_address, data, chain) do
      {:ok, result != "0x" <> String.duplicate("0", 63) <> "0"}
    end
  end

  # ── Explorer URL helpers ──────────────────────────────────────────────────────

  def explorer_tx_url(tx_hash, :testnet),
    do: "https://testnet.kitescan.ai/tx/#{tx_hash}"

  def explorer_tx_url(tx_hash, :mainnet),
    do: "https://kitescan.ai/tx/#{tx_hash}"

  def explorer_address_url(address, :testnet),
    do: "https://testnet.kitescan.ai/address/#{address}"

  # ── Private ───────────────────────────────────────────────────────────────────

  defp rpc_url(:testnet), do: @testnet_rpc
  defp rpc_url(:mainnet), do: @mainnet_rpc

  defp call(method, params, chain) do
    payload = %{
      jsonrpc: "2.0",
      id: 1,
      method: method,
      params: params
    }

    case Req.post(rpc_url(chain), json: payload, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"result" => result}}} ->
        {:ok, result}

      {:ok, %{status: 200, body: %{"error" => %{"message" => msg}}}} ->
        {:error, msg}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_hex_integer({:ok, "0x"}), do: {:ok, 0}

  defp decode_hex_integer({:ok, "0x" <> hex}) do
    {:ok, String.to_integer(hex, 16)}
  end

  defp decode_hex_integer({:ok, nil}), do: {:ok, 0}
  defp decode_hex_integer({:error, _} = err), do: err
  defp decode_hex_integer(other), do: other
end
