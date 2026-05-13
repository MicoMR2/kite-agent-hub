defmodule KiteAgentHub.Credentials.BrokerSlugTest do
  use ExUnit.Case, async: true

  alias KiteAgentHub.Credentials

  @testnet 2368
  @mainnet 2366

  describe "broker_slug_for/2 — paper / live routing" do
    test "testnet agent → paper slug for alpaca/kalshi/oanda" do
      agent = %{id: "a-1", chain_id: @testnet}

      assert {:ok, "alpaca"} = Credentials.broker_slug_for(agent, "alpaca")
      assert {:ok, "kalshi"} = Credentials.broker_slug_for(agent, "kalshi")
      assert {:ok, "oanda"} = Credentials.broker_slug_for(agent, "oanda")
    end

    test "mainnet agent → live slug for alpaca/kalshi/oanda" do
      agent = %{id: "a-2", chain_id: @mainnet}

      assert {:ok, "alpaca_live"} = Credentials.broker_slug_for(agent, "alpaca")
      assert {:ok, "kalshi_live"} = Credentials.broker_slug_for(agent, "kalshi")
      assert {:ok, "oanda_live"} = Credentials.broker_slug_for(agent, "oanda")
    end

    test "polymarket carve-out — always returns polymarket regardless of chain" do
      assert {:ok, "polymarket"} =
               Credentials.broker_slug_for(%{id: "a", chain_id: @testnet}, "polymarket")

      assert {:ok, "polymarket"} =
               Credentials.broker_slug_for(%{id: "a", chain_id: @mainnet}, "polymarket")

      assert {:ok, "polymarket"} =
               Credentials.broker_slug_for(%{id: "a", chain_id: nil}, :polymarket)
    end

    test "atom broker_root is normalized to string" do
      agent = %{id: "a", chain_id: @testnet}
      assert {:ok, "alpaca"} = Credentials.broker_slug_for(agent, :alpaca)
    end

    test "nil chain_id falls back to paper slug" do
      agent = %{id: "a", chain_id: nil}

      assert {:ok, "alpaca"} = Credentials.broker_slug_for(agent, "alpaca")
    end

    test "unknown broker_root returns {:error, :invalid_broker}" do
      agent = %{id: "a", chain_id: @testnet}

      assert {:error, :invalid_broker} = Credentials.broker_slug_for(agent, "bogus")
    end
  end

  describe "ApiCredential allowlist" do
    test "new live slugs are accepted by the changeset" do
      org_id = Ecto.UUID.generate()

      for slug <- [
            "alpaca",
            "alpaca_live",
            "kalshi",
            "kalshi_live",
            "oanda",
            "oanda_live",
            "polymarket"
          ] do
        key_id =
          if slug == "polymarket",
            do: "0x" <> String.duplicate("a", 40),
            else: "key12345"

        cs =
          KiteAgentHub.Credentials.ApiCredential.changeset(
            %KiteAgentHub.Credentials.ApiCredential{},
            %{
              "org_id" => org_id,
              "provider" => slug,
              "key_id" => key_id,
              "secret" => "secretvalue1234"
            }
          )

        assert cs.valid?, "#{slug} should be a valid provider but got #{inspect(cs.errors)}"
      end
    end

    test "unknown slug is rejected" do
      org_id = Ecto.UUID.generate()

      cs =
        KiteAgentHub.Credentials.ApiCredential.changeset(
          %KiteAgentHub.Credentials.ApiCredential{},
          %{
            "org_id" => org_id,
            "provider" => "polymarket_paper",
            "key_id" => "key12345",
            "secret" => "secretvalue1234"
          }
        )

      refute cs.valid?
      assert {_msg, _} = cs.errors[:provider]
    end

    test "live_providers/0 lists the four live slugs" do
      assert KiteAgentHub.Credentials.ApiCredential.live_providers() ==
               ~w(alpaca_live kalshi_live oanda_live polymarket)
    end
  end
end
