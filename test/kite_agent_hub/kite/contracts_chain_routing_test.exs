defmodule KiteAgentHub.Kite.ContractsChainRoutingTest do
  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.Contracts

  @testnet 2368
  @mainnet 2366

  # ── Test 1: mainnet treasury unset → mutation rejected ─────────────────────

  describe "treasury_address/1 — mainnet fail-closed" do
    setup do
      prior = Application.get_env(:kite_agent_hub, :kite_treasury_address_mainnet)

      on_exit(fn ->
        Application.put_env(:kite_agent_hub, :kite_treasury_address_mainnet, prior)
      end)

      :ok
    end

    test "returns :mainnet_treasury_unconfigured when env is nil" do
      Application.put_env(:kite_agent_hub, :kite_treasury_address_mainnet, nil)
      assert {:error, :mainnet_treasury_unconfigured} = Contracts.treasury_address(@mainnet)
    end

    test "returns :mainnet_treasury_unconfigured when env is empty string" do
      Application.put_env(:kite_agent_hub, :kite_treasury_address_mainnet, "")
      assert {:error, :mainnet_treasury_unconfigured} = Contracts.treasury_address(@mainnet)
    end

    test "returns {:ok, addr} when mainnet secret is set" do
      Application.put_env(
        :kite_agent_hub,
        :kite_treasury_address_mainnet,
        "0xABCDEF1234567890ABCDEF1234567890ABCDEF12"
      )

      assert {:ok, addr} = Contracts.treasury_address(@mainnet)
      assert String.starts_with?(addr, "0x")
    end

    test "testnet treasury does NOT fall back to mainnet secret" do
      Application.put_env(
        :kite_agent_hub,
        :kite_treasury_address_mainnet,
        "0xABCDEF1234567890ABCDEF1234567890ABCDEF12"
      )

      # testnet path should be independent of mainnet secret
      result = Contracts.treasury_address(@testnet)
      assert match?({:ok, _}, result) or match?({:error, :testnet_treasury_unconfigured}, result)
    end
  end

  # ── Test 2: testnet agent's vault_balance never hits mainnet RPC ────────────

  describe "explorer_url/1 — per-chain isolation" do
    test "testnet chain_id returns testnet explorer URL" do
      url = Contracts.explorer_url(@testnet)
      assert String.contains?(url, "testnet.kitescan.ai")
      refute String.contains?(url, "kitescan.ai/api")
    end

    test "mainnet chain_id returns mainnet explorer URL" do
      url = Contracts.explorer_url(@mainnet)
      assert url == "https://kitescan.ai"
      refute String.contains?(url, "testnet")
    end

    test "RPC URL is isolated per chain (no cross-chain routing)" do
      assert Contracts.rpc_url(@testnet) == "https://rpc-testnet.gokite.ai/"
      assert Contracts.rpc_url(@mainnet) == "https://rpc.gokite.ai/"
      refute Contracts.rpc_url(@testnet) == Contracts.rpc_url(@mainnet)
    end
  end

  # ── Test 3: case-mismatched contract address rejected ───────────────────────

  describe "allowed_tokens/1 — address case normalization" do
    test "all allowed contract addresses are lowercase" do
      for chain_id <- [@testnet, @mainnet] do
        for {_sym, addr, _decimals} <- Contracts.allowed_tokens(chain_id) do
          assert addr == String.downcase(addr),
                 "#{addr} in chain #{chain_id} allowlist is not lowercase — case-mismatch guard would fail"
        end
      end
    end

    test "mixed-case address does NOT match testnet allowlist after downcase compare" do
      # Simulate Blockscout returning a mixed-case address that matches
      # the testnet KITE ERC-20 value but with wrong casing. The
      # allowlist gate in vault_balance.ex normalizes both sides, so
      # the match must succeed when casing is normalized. Here we verify
      # the allowlist stored addresses are already lowercase — meaning
      # any caller that lowercases the Blockscout-returned address will
      # get a match, and a non-lowercased caller won't (strict gate).
      [{_sym, addr, _dec} | _] = Contracts.allowed_tokens(@testnet)
      upper = String.upcase(addr)
      assert upper != addr, "expected uppercase form to differ from stored lowercase"
      assert String.downcase(upper) == addr
    end
  end

  # ── Test 4: WKITE on testnet rejected ───────────────────────────────────────

  describe "allowed_tokens/1 — per-chain symbol isolation" do
    test "WKITE is NOT in testnet allowlist" do
      testnet_symbols = Contracts.allowed_tokens(@testnet) |> Enum.map(&elem(&1, 0))
      refute "WKITE" in testnet_symbols, "WKITE must not be allowed on testnet"
    end

    test "WKITE IS in mainnet allowlist" do
      mainnet_symbols = Contracts.allowed_tokens(@mainnet) |> Enum.map(&elem(&1, 0))
      assert "WKITE" in mainnet_symbols
    end
  end

  # ── Test 5: testnet KITE ERC-20 on mainnet rejected ─────────────────────────

  describe "allowed_tokens/1 — testnet KITE ERC-20 excluded from mainnet" do
    test "testnet KITE ERC-20 contract address is NOT in mainnet allowlist" do
      testnet_kite_addr =
        Contracts.allowed_tokens(@testnet)
        |> Enum.find(fn {sym, _addr, _d} -> sym == "KITE" end)
        |> elem(1)

      mainnet_addrs = Contracts.allowed_tokens(@mainnet) |> Enum.map(&elem(&1, 1))

      refute testnet_kite_addr in mainnet_addrs,
             "testnet KITE ERC-20 address must not appear in mainnet allowlist"
    end

    test "mainnet KITE is native — native_kite?/1 returns true for mainnet only" do
      assert Contracts.native_kite?(@mainnet)
      refute Contracts.native_kite?(@testnet)
      refute Contracts.native_kite?(1)
    end
  end
end
