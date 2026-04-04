defmodule KiteAgentHub.Kite.Blockscout do
  @moduledoc """
  Blockscout v2 API client for Kite testnet (testnet.kitescan.ai).

  Fetches on-chain transaction history, token balances, and contract
  data for agent wallets and vaults.
  """
  require Logger

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
  def token_balances(address) do
    case get("/addresses/#{address}/token-balances") do
      {:ok, items} when is_list(items) ->
        balances =
          Enum.map(items, fn item ->
            token = item["token"] || %{}
            %{
              token: token["name"] || "Unknown",
              symbol: token["symbol"] || "???",
              balance: item["value"] || "0",
              decimals: token["decimals"] || 18
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
  def address_info(address) do
    case get("/addresses/#{address}") do
      {:ok, data} when is_map(data) ->
        balance_wei = data["coin_balance"] || "0"
        balance_eth = wei_to_eth(balance_wei)

        {:ok, %{
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

  defp get(path) do
    url = @base_url <> path

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
