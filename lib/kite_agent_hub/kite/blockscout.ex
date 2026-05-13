defmodule KiteAgentHub.Kite.Blockscout do
  @moduledoc """
  Blockscout v2 API client for Kite testnet (testnet.kitescan.ai).

  Fetches on-chain transaction history, token balances, and contract
  data for agent wallets and vaults.
  """
  require Logger

  alias KiteAgentHub.Kite.{ChainId, Contracts}

  # Legacy default base URL retained for the `/1` helpers, which now
  # delegate to the chain-aware `/2` variants below using
  # `ChainId.default/0`. Direct callers should pass the agent's
  # `chain_id` explicitly via the `/2` variants — chain-mismatch is a
  # real-money correctness bug (CyberSec ask 4, msg 9264).
  @base_url "https://testnet.kitescan.ai/api/v2"

  @doc """
  Fetch recent transactions for a wallet address.
  Returns {:ok, [tx_map]} or {:error, reason}.
  """
  def transactions(address, limit \\ 10) do
    case get("/addresses/#{address}/transactions") do
      {:ok, %{"items" => items}} when is_list(items) ->
        txs =
          items
          |> Enum.take(limit)
          |> Enum.map(&parse_tx/1)

        {:ok, txs}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Fetch token balances for a wallet address.
  Returns {:ok, [%{token, symbol, balance, decimals}]} or {:error, reason}.
  """
  def token_balances(address), do: token_balances(address, ChainId.default())

  def token_balances(address, chain_id) when is_integer(chain_id) do
    case get_for_chain("/addresses/#{address}/token-balances", chain_id) do
      {:ok, items} when is_list(items) ->
        balances =
          Enum.map(items, fn item ->
            token = item["token"] || %{}

            %{
              token: token["name"] || "Unknown",
              symbol: token["symbol"] || "???",
              balance: item["value"] || "0",
              decimals: token["decimals"] || 18,
              contract_address:
                (token["address_hash"] || token["address"] || "")
                |> to_string()
                |> String.downcase()
            }
          end)

        {:ok, balances}

      {:ok, _} ->
        {:ok, []}

      err ->
        err
    end
  end

  @doc """
  Fetch native coin balance for a wallet address.
  Returns {:ok, %{balance_wei, balance_eth}} or {:error, reason}.
  """
  def address_info(address), do: address_info(address, ChainId.default())

  def address_info(address, chain_id) when is_integer(chain_id) do
    case get_for_chain("/addresses/#{address}", chain_id) do
      {:ok, data} when is_map(data) ->
        balance_wei = data["coin_balance"] || "0"
        balance_eth = wei_to_eth(balance_wei)

        {:ok,
         %{
           balance_wei: balance_wei,
           balance_eth: balance_eth,
           tx_count: data["transactions_count"] || 0,
           token_transfers_count: data["token_transfers_count"] || 0
         }}

      err ->
        err
    end
  end

  # --- Private ---

  # Chain-aware variant. The base URL is selected ONCE at the start
  # of the request from `Contracts.explorer_url/1` so a mid-call
  # chain_id mutation (impossible in practice, but the invariant
  # CyberSec ask 4 demands) cannot change which RPC was used.
  defp get_for_chain(path, chain_id) do
    base = Contracts.explorer_url(chain_id) <> "/api/v2"
    url = base <> path
    request(url, path)
  end

  defp get(path) do
    url = @base_url <> path
    request(url, path)
  end

  defp request(url, path) do
    case Req.get(url, receive_timeout: 10_000, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        Logger.warning("Blockscout: HTTP #{status} for #{path}")
        {:error, {:api_error, status}}

      {:error, reason} ->
        Logger.error("Blockscout: request failed for #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_tx(tx) do
    %{
      hash: tx["hash"],
      from: get_in(tx, ["from", "hash"]),
      to: get_in(tx, ["to", "hash"]),
      value_wei: tx["value"] || "0",
      value_eth: wei_to_eth(tx["value"] || "0"),
      status: tx["status"],
      block: tx["block"],
      timestamp: tx["timestamp"],
      method: tx["method"] || tx["transaction_tag"],
      gas_used: tx["gas_used"],
      fee: tx["fee"] && wei_to_eth(to_string(tx["fee"]["value"] || "0"))
    }
  end

  defp wei_to_eth(wei_str) when is_binary(wei_str) do
    case Integer.parse(wei_str) do
      {wei, _} -> Float.round(wei / 1.0e18, 6)
      :error -> 0.0
    end
  end

  defp wei_to_eth(_), do: 0.0
end
