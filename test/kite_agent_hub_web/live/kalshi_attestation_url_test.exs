defmodule KiteAgentHubWeb.KalshiAttestationUrlTest do
  @moduledoc """
  PR-J.5.1 attestation explorer URL builder coverage. The contract
  CyberSec locked at 10911 ①+②: only render a link when the tx
  hash is the canonical 0x-prefixed 32-byte hex, and resolve the
  explorer base via the chain registry (testnet vs mainnet).
  """

  use ExUnit.Case, async: true

  alias KiteAgentHubWeb.DashboardLive

  @testnet_id 2368
  @mainnet_id 2366

  test "valid 32-byte hex hash + testnet chain → testnet kitescan tx url" do
    hash = "0x" <> String.duplicate("a", 64)
    assert "https://testnet.kitescan.ai/tx/" <> ^hash =
             DashboardLive.kalshi_attestation_url(hash, @testnet_id)
  end

  test "valid hash + mainnet chain → mainnet kitescan tx url" do
    hash = "0x" <> String.duplicate("b", 64)
    assert "https://kitescan.ai/tx/" <> ^hash =
             DashboardLive.kalshi_attestation_url(hash, @mainnet_id)
  end

  test "uppercase hex chars accepted (Ethereum mixed-case)" do
    hash = "0x" <> String.duplicate("A", 32) <> String.duplicate("F", 32)
    assert "https://testnet.kitescan.ai/tx/" <> ^hash =
             DashboardLive.kalshi_attestation_url(hash, @testnet_id)
  end

  test "missing 0x prefix → nil (no link)" do
    hash = String.duplicate("a", 64)
    assert nil == DashboardLive.kalshi_attestation_url(hash, @testnet_id)
  end

  test "wrong length → nil" do
    short = "0x" <> String.duplicate("a", 30)
    long = "0x" <> String.duplicate("a", 100)
    assert nil == DashboardLive.kalshi_attestation_url(short, @testnet_id)
    assert nil == DashboardLive.kalshi_attestation_url(long, @testnet_id)
  end

  test "non-hex character in hash → nil" do
    hash = "0x" <> String.duplicate("g", 64)
    assert nil == DashboardLive.kalshi_attestation_url(hash, @testnet_id)
  end

  test "path traversal / javascript scheme → nil" do
    assert nil == DashboardLive.kalshi_attestation_url("../../../etc/passwd", @testnet_id)
    assert nil == DashboardLive.kalshi_attestation_url("javascript:alert(1)", @testnet_id)
  end

  test "nil / non-binary / non-integer → nil" do
    assert nil == DashboardLive.kalshi_attestation_url(nil, @testnet_id)
    assert nil == DashboardLive.kalshi_attestation_url(123, @testnet_id)
    assert nil == DashboardLive.kalshi_attestation_url("0x" <> String.duplicate("a", 64), nil)
    assert nil == DashboardLive.kalshi_attestation_url("0x" <> String.duplicate("a", 64), "2368")
  end

  test "unknown chain_id falls back to testnet explorer (via Contracts.explorer_url default)" do
    hash = "0x" <> String.duplicate("a", 64)

    assert "https://testnet.kitescan.ai/tx/" <> ^hash =
             DashboardLive.kalshi_attestation_url(hash, 99_999)
  end
end
