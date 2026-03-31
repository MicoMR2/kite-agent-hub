defmodule KiteAgentHub.Kite.GaslessClient do
  @moduledoc """
  Submits gasless token transfers via Kite's EIP-3009 relayer.

  No KITE gas required — the relayer covers gas costs. The caller signs an
  EIP-712 `TransferWithAuthorization` message off-chain; the relayer broadcasts
  the transaction on their behalf.

  Supported tokens:
    - Testnet: PYUSD  — 0x8E04D099b1a8Dd20E6caD4b2Ab2B405B98242ec9 (18 decimals)
    - Mainnet: USDC.e — 0x7aB6f3ed87C42eF0aDb67Ed95090f8bF5240149e (6 decimals)

  Usage:

      # Deposit 10 PYUSD (10 * 10^18 units) to a vault on testnet
      {:ok, tx_hash} = GaslessClient.deposit_to_vault(private_key_hex, vault_address, 10)

      # Raw transfer of any amount (in token units)
      {:ok, tx_hash} = GaslessClient.transfer(private_key_hex, to_address, amount_units)
  """

  alias KiteAgentHub.Kite.TxSigner

  @testnet_relayer "https://gasless.gokite.ai/testnet"
  @mainnet_relayer "https://gasless.gokite.ai/mainnet"

  @tokens %{
    testnet: %{
      address: "0x8E04D099b1a8Dd20E6caD4b2Ab2B405B98242ec9",
      name: "PayPal USD",
      decimals: 18,
      chain_id: 2368
    },
    mainnet: %{
      address: "0x7aB6f3ed87C42eF0aDb67Ed95090f8bF5240149e",
      name: "Bridged USDC (Kite AI)",
      decimals: 6,
      chain_id: 2366
    }
  }

  @transfer_typehash_input "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
  @domain_typehash_input "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

  @doc """
  Convenience wrapper: deposit `amount_whole` whole token units (e.g. 10 for 10 PYUSD)
  to a vault address. Converts to token base units internally.

  Returns {:ok, tx_hash} or {:error, reason}.
  """
  def deposit_to_vault(private_key_hex, vault_address, amount_whole, network \\ :testnet) do
    token = @tokens[network]
    amount_units = round(amount_whole * :math.pow(10, token.decimals))
    transfer(private_key_hex, vault_address, amount_units, network)
  end

  @doc """
  Transfer `amount_units` (smallest token denomination) from the wallet identified
  by `private_key_hex` to `to_address` via Kite's gasless relayer.

  Returns {:ok, tx_hash} or {:error, reason}.
  """
  def transfer(private_key_hex, to_address, amount_units, network \\ :testnet)
      when network in [:testnet, :mainnet] and is_integer(amount_units) and amount_units > 0 do
    token = @tokens[network]
    relayer = if network == :testnet, do: @testnet_relayer, else: @mainnet_relayer

    with {:ok, from_address} <- TxSigner.address_from_private_key(private_key_hex),
         {:ok, sig} <- sign_transfer_auth(private_key_hex, from_address, to_address, amount_units, token),
         {:ok, tx_hash} <- submit_to_relayer(relayer, token.address, from_address, to_address, amount_units, sig) do
      {:ok, tx_hash}
    end
  end

  @doc """
  Return the token info map for the given network (:testnet | :mainnet).
  Useful for displaying token symbol and decimals in the UI.
  """
  def token_info(network \\ :testnet), do: @tokens[network]

  # ── Private ───────────────────────────────────────────────────────────────────

  defp sign_transfer_auth(private_key_hex, from_address, to_address, value, token) do
    # validAfter = 0 → valid immediately
    # validBefore = now + 30s (Kite relayer requires ≤ 30-second window)
    valid_after = 0
    valid_before = System.os_time(:second) + 30
    nonce = :crypto.strong_rand_bytes(32)

    domain_sep = domain_separator(token.name, token.chain_id, token.address)
    s_hash = struct_hash(from_address, to_address, value, valid_after, valid_before, nonce)

    # EIP-712: keccak256("\x19\x01" || domainSeparator || structHash)
    digest = ExKeccak.hash_256(<<0x19, 0x01>> <> domain_sep <> s_hash)

    with {:ok, priv_bytes} <- decode_private_key(private_key_hex),
         {:ok, {r, s, recovery_id}} <- ExSecp256k1.sign(digest, priv_bytes) do
      {:ok, %{
        v: recovery_id + 27,
        r: "0x" <> Base.encode16(r, case: :lower),
        s: "0x" <> Base.encode16(s, case: :lower),
        valid_after: valid_after,
        valid_before: valid_before,
        nonce: "0x" <> Base.encode16(nonce, case: :lower)
      }}
    else
      {:error, reason} -> {:error, "signing failed: #{inspect(reason)}"}
    end
  end

  defp submit_to_relayer(url, token_address, from, to, value, sig) do
    body = %{
      "from" => from,
      "to" => to,
      "value" => Integer.to_string(value),
      "validAfter" => Integer.to_string(sig.valid_after),
      "validBefore" => Integer.to_string(sig.valid_before),
      "tokenAddress" => token_address,
      "nonce" => sig.nonce,
      "v" => sig.v,
      "r" => sig.r,
      "s" => sig.s
    }

    case Req.post(url, json: body) do
      {:ok, %{status: 200, body: %{"txHash" => tx_hash}}} ->
        {:ok, tx_hash}

      {:ok, %{status: status, body: body}} ->
        {:error, "relayer #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "relayer HTTP error: #{inspect(reason)}"}
    end
  end

  # ── EIP-712 encoding ──────────────────────────────────────────────────────────

  defp domain_separator(name, chain_id, contract_address) do
    typehash = ExKeccak.hash_256(@domain_typehash_input)
    name_hash = ExKeccak.hash_256(name)
    version_hash = ExKeccak.hash_256("1")

    ExKeccak.hash_256(
      pad_bytes32(typehash) <>
        pad_bytes32(name_hash) <>
        pad_bytes32(version_hash) <>
        pad_uint256(chain_id) <>
        pad_address(contract_address)
    )
  end

  defp struct_hash(from, to, value, valid_after, valid_before, nonce) do
    typehash = ExKeccak.hash_256(@transfer_typehash_input)

    ExKeccak.hash_256(
      pad_bytes32(typehash) <>
        pad_address(from) <>
        pad_address(to) <>
        pad_uint256(value) <>
        pad_uint256(valid_after) <>
        pad_uint256(valid_before) <>
        pad_bytes32(nonce)
    )
  end

  # ABI-encodes bytes32: already 32 bytes, zero-pad shorter values on the left
  defp pad_bytes32(b) when byte_size(b) == 32, do: b
  defp pad_bytes32(b) when byte_size(b) < 32, do: <<0::((32 - byte_size(b)) * 8)>> <> b

  # ABI-encodes uint256 as big-endian 32-byte value
  defp pad_uint256(0), do: <<0::256>>

  defp pad_uint256(n) when is_integer(n) and n > 0 do
    hex = Integer.to_string(n, 16)
    hex = if rem(String.length(hex), 2) == 0, do: hex, else: "0" <> hex
    raw = Base.decode16!(hex, case: :upper)
    <<0::((32 - byte_size(raw)) * 8)>> <> raw
  end

  # ABI-encodes address as 32 bytes (12 zero bytes + 20-byte address)
  defp pad_address("0x" <> hex), do: <<0::96>> <> Base.decode16!(hex, case: :mixed)
  defp pad_address(hex), do: <<0::96>> <> Base.decode16!(hex, case: :mixed)

  defp decode_private_key("0x" <> hex), do: decode_private_key(hex)

  defp decode_private_key(hex) when byte_size(hex) == 64 do
    {:ok, Base.decode16!(hex, case: :mixed)}
  rescue
    _ -> {:error, "invalid private key hex"}
  end

  defp decode_private_key(_), do: {:error, "private key must be 64 hex chars (32 bytes)"}
end
