defmodule KiteAgentHub.Kite.TxSigner do
  @moduledoc """
  EIP-155 Ethereum transaction signer for Kite chain.

  Signs and encodes raw transactions using a private key.
  Supports EIP-155 replay protection (chain_id included in signature).

  Usage:

      private_key = System.get_env("AGENT_PRIVATE_KEY")  # 32-byte hex, no 0x prefix

      tx = %{
        nonce: 0,
        gas_price: 1_000_000_000,   # 1 gwei in wei
        gas_limit: 21_000,
        to: "0xRecipientAddress",
        value: 0,
        data: ""
      }

      {:ok, signed_hex} = TxSigner.sign(tx, private_key, chain_id: 2368)
      # => "0x02f8..."

  Then submit via RPC.send_raw_transaction(signed_hex).
  """

  @kite_testnet_chain_id 2368

  @doc """
  Sign a transaction map and return the hex-encoded RLP for eth_sendRawTransaction.
  chain_id defaults to Kite testnet (2368).
  """
  def sign(tx, private_key_hex, opts \\ []) do
    chain_id = Keyword.get(opts, :chain_id, @kite_testnet_chain_id)

    with {:ok, priv_key_bytes} <- decode_private_key(private_key_hex),
         {:ok, signing_hash} <- build_signing_hash(tx, chain_id),
         {:ok, {r, s, v_recovery}} <- ExSecp256k1.sign(signing_hash, priv_key_bytes) do
      # EIP-155: v = recovery_id + chain_id * 2 + 35
      v = v_recovery + chain_id * 2 + 35

      encoded =
        ExRLP.encode([
          encode_int(tx.nonce),
          encode_int(tx.gas_price),
          encode_int(tx.gas_limit),
          decode_address(tx.to),
          encode_int(tx.value || 0),
          decode_data(tx.data || ""),
          encode_int(v),
          r,
          s
        ])

      {:ok, "0x" <> Base.encode16(encoded, case: :lower)}
    end
  end

  @doc "Derive the public Ethereum address from a private key hex string."
  def address_from_private_key(private_key_hex) do
    with {:ok, priv_bytes} <- decode_private_key(private_key_hex),
         {:ok, pub_key} <- ExSecp256k1.create_public_key(priv_bytes) do
      # Public key is 65 bytes (uncompressed, 0x04 prefix) — drop the prefix
      <<_prefix::binary-size(1), pub_without_prefix::binary>> = pub_key
      keccak = ExKeccak.hash_256(pub_without_prefix)
      # Take last 20 bytes = address
      <<_::binary-size(12), address_bytes::binary-size(20)>> = keccak
      {:ok, "0x" <> Base.encode16(address_bytes, case: :lower)}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  defp build_signing_hash(tx, chain_id) do
    # EIP-155 pre-image: RLP([nonce, gas_price, gas_limit, to, value, data, chain_id, 0, 0])
    pre_image =
      ExRLP.encode([
        encode_int(tx.nonce),
        encode_int(tx.gas_price),
        encode_int(tx.gas_limit),
        decode_address(tx.to),
        encode_int(tx.value || 0),
        decode_data(tx.data || ""),
        encode_int(chain_id),
        encode_int(0),
        encode_int(0)
      ])

    {:ok, ExKeccak.hash_256(pre_image)}
  end

  defp decode_private_key("0x" <> hex), do: decode_private_key(hex)

  defp decode_private_key(hex) when byte_size(hex) == 64 do
    {:ok, Base.decode16!(hex, case: :mixed)}
  rescue
    _ -> {:error, "invalid private key hex"}
  end

  defp decode_private_key(_), do: {:error, "private key must be 64 hex chars (32 bytes)"}

  defp decode_address("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_address(hex), do: Base.decode16!(hex, case: :mixed)

  defp decode_data(""), do: ""
  defp decode_data("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_data(hex), do: Base.decode16!(hex, case: :mixed)

  # RLP encodes integers: 0 → "", positive → big-endian binary with no leading zeros
  defp encode_int(0), do: ""

  defp encode_int(n) when is_integer(n) and n > 0 do
    hex = Integer.to_string(n, 16)
    padded = if rem(byte_size(hex), 2) == 0, do: hex, else: "0" <> hex
    Base.decode16!(padded, case: :upper)
  end
end
