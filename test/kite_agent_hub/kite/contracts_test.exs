defmodule KiteAgentHub.Kite.ContractsTest do
  use ExUnit.Case, async: false

  alias KiteAgentHub.Kite.Contracts

  @testnet 2368
  @mainnet 2366

  describe "rpc_url/1" do
    test "returns the testnet endpoint for chain 2368" do
      assert Contracts.rpc_url(@testnet) == "https://rpc-testnet.gokite.ai/"
    end

    test "returns the mainnet endpoint for chain 2366" do
      assert Contracts.rpc_url(@mainnet) == "https://rpc.gokite.ai/"
    end
  end

  describe "explorer_url/1" do
    test "testnet -> testnet.kitescan.ai" do
      assert Contracts.explorer_url(@testnet) == "https://testnet.kitescan.ai"
    end

    test "mainnet -> kitescan.ai" do
      assert Contracts.explorer_url(@mainnet) == "https://kitescan.ai"
    end
  end

  describe "allowed_tokens/1" do
    test "testnet allowlist includes ERC-20 KITE but NOT WKITE" do
      tokens = Contracts.allowed_tokens(@testnet)
      symbols = Enum.map(tokens, fn {sym, _addr, _d} -> sym end)

      assert "KITE" in symbols
      refute "WKITE" in symbols
    end

    test "mainnet allowlist includes WKITE but NOT ERC-20 KITE" do
      tokens = Contracts.allowed_tokens(@mainnet)
      symbols = Enum.map(tokens, fn {sym, _addr, _d} -> sym end)

      assert "WKITE" in symbols
      refute "KITE" in symbols
    end

    test "USDC.e and USDT live on both chains' allowlists" do
      for chain <- [@testnet, @mainnet] do
        symbols = Contracts.allowed_tokens(chain) |> Enum.map(fn {s, _, _} -> s end)
        assert "USDC.e" in symbols
        assert "USDT" in symbols
      end
    end

    test "all contract addresses are lowercase (case-safe comparison ready)" do
      for chain <- [@testnet, @mainnet] do
        for {_sym, addr, _d} <- Contracts.allowed_tokens(chain) do
          assert addr == String.downcase(addr)
        end
      end
    end
  end

  describe "native_kite?/1" do
    test "mainnet only" do
      assert Contracts.native_kite?(@mainnet)
      refute Contracts.native_kite?(@testnet)
    end
  end

  describe "treasury_address/1 — CyberSec ask 2 hard fail-closed" do
    setup do
      prior_testnet = Application.get_env(:kite_agent_hub, :kite_treasury_address)
      prior_mainnet = Application.get_env(:kite_agent_hub, :kite_treasury_address_mainnet)
      prior_env_testnet = System.get_env("KITE_TREASURY_ADDRESS")
      prior_env_mainnet = System.get_env("KITE_TREASURY_ADDRESS_MAINNET")

      System.delete_env("KITE_TREASURY_ADDRESS")
      System.delete_env("KITE_TREASURY_ADDRESS_MAINNET")
      Application.delete_env(:kite_agent_hub, :kite_treasury_address)
      Application.delete_env(:kite_agent_hub, :kite_treasury_address_mainnet)

      on_exit(fn ->
        if prior_env_testnet, do: System.put_env("KITE_TREASURY_ADDRESS", prior_env_testnet)
        if prior_env_mainnet, do: System.put_env("KITE_TREASURY_ADDRESS_MAINNET", prior_env_mainnet)
        if prior_testnet, do: Application.put_env(:kite_agent_hub, :kite_treasury_address, prior_testnet)
        if prior_mainnet, do: Application.put_env(:kite_agent_hub, :kite_treasury_address_mainnet, prior_mainnet)
      end)

      :ok
    end

    test "mainnet with no env set returns :mainnet_treasury_unconfigured — no testnet fallback" do
      Application.put_env(:kite_agent_hub, :kite_treasury_address, "0x4049c35f45F772FE0cB207a9905eBD55C0635714")

      assert {:error, :mainnet_treasury_unconfigured} = Contracts.treasury_address(@mainnet)
    end

    test "mainnet returns the configured address when set" do
      Application.put_env(:kite_agent_hub, :kite_treasury_address_mainnet, "0xMAINNETADDRESS_PLACEHOLDER")

      assert {:ok, "0xMAINNETADDRESS_PLACEHOLDER"} = Contracts.treasury_address(@mainnet)
    end

    test "testnet returns its address when set" do
      Application.put_env(:kite_agent_hub, :kite_treasury_address, "0x4049c35f45F772FE0cB207a9905eBD55C0635714")

      assert {:ok, "0x4049c35f45F772FE0cB207a9905eBD55C0635714"} = Contracts.treasury_address(@testnet)
    end

    test "unknown chain returns :unknown_chain" do
      assert {:error, :unknown_chain} = Contracts.treasury_address(99999)
    end
  end
end
