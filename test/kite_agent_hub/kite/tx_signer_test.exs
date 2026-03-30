defmodule KiteAgentHub.Kite.TxSignerTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Kite.TxSigner

  # Well-known test key — DO NOT use for real funds
  # This is the Ethereum Foundation's well-known test private key from the docs
  @test_private_key "4c0883a69102937d6231471b5dbb6e538eba2ef05b2a5e9a9ee6d5e9bb0cde3d"
  @expected_address "0x2c7536e3605d9c16a7a3d7b1898e529396a65c23"

  describe "address_from_private_key/1" do
    test "derives correct Ethereum address from known private key" do
      assert {:ok, address} = TxSigner.address_from_private_key(@test_private_key)
      assert address == @expected_address
    end

    test "accepts 0x-prefixed key" do
      assert {:ok, address} = TxSigner.address_from_private_key("0x" <> @test_private_key)
      assert address == @expected_address
    end

    test "returns error for invalid key length" do
      assert {:error, _} = TxSigner.address_from_private_key("tooshort")
    end
  end

  describe "sign/3" do
    test "produces a valid RLP-encoded hex string" do
      tx = %{
        nonce: 0,
        gas_price: 1_000_000_000,
        gas_limit: 21_000,
        to: "0x2c7536e3605d9c16a7a3d7b1898e529396a65c23",
        value: 0,
        data: ""
      }

      assert {:ok, signed} = TxSigner.sign(tx, @test_private_key, chain_id: 2368)
      assert String.starts_with?(signed, "0x")
      # Should be at least 100 hex chars for a minimal tx
      assert byte_size(signed) > 100
    end

    test "signed tx for chain_id 2368 differs from chain_id 1 (replay protection)" do
      tx = %{
        nonce: 1,
        gas_price: 2_000_000_000,
        gas_limit: 50_000,
        to: "0x2c7536e3605d9c16a7a3d7b1898e529396a65c23",
        value: 0,
        data: ""
      }

      {:ok, kite_signed} = TxSigner.sign(tx, @test_private_key, chain_id: 2368)
      {:ok, eth_signed} = TxSigner.sign(tx, @test_private_key, chain_id: 1)

      refute kite_signed == eth_signed
    end
  end
end
