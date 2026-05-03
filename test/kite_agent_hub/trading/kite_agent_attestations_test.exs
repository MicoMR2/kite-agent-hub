defmodule KiteAgentHub.Trading.KiteAgentAttestationsTest do
  @moduledoc """
  Behavioural tests for the attestations-optional gate.

  Two invariants:
    1. A trading agent can be created with attestations OFF and no wallet.
    2. A trading agent with attestations ON must have a valid wallet.

  Plus the profile_changeset path so users can flip the toggle later.
  """

  use ExUnit.Case, async: true

  alias KiteAgentHub.Trading.KiteAgent

  @valid_wallet "0x0000000000000000000000000000000000000001"
  @org_id Ecto.UUID.generate()

  describe "changeset/2 — wallet requirement gated by attestations_enabled" do
    test "trading agent with attestations OFF needs no wallet" do
      cs =
        KiteAgent.changeset(%KiteAgent{}, %{
          "name" => "Free Trader",
          "agent_type" => "trading",
          "organization_id" => @org_id,
          "attestations_enabled" => false
        })

      assert cs.valid?, "expected valid, got: #{inspect(cs.errors)}"
      assert get_field(cs, :attestations_enabled) == false
      assert get_field(cs, :wallet_address) in [nil, ""]
    end

    test "trading agent with attestations ON requires a wallet" do
      cs =
        KiteAgent.changeset(%KiteAgent{}, %{
          "name" => "On-chain Trader",
          "agent_type" => "trading",
          "organization_id" => @org_id,
          "attestations_enabled" => true
        })

      refute cs.valid?
      assert {"is required when attestations are enabled", _} = cs.errors[:wallet_address]
    end

    test "trading agent with attestations ON and a valid wallet is accepted" do
      cs =
        KiteAgent.changeset(%KiteAgent{}, %{
          "name" => "On-chain Trader",
          "agent_type" => "trading",
          "organization_id" => @org_id,
          "attestations_enabled" => true,
          "wallet_address" => @valid_wallet
        })

      assert cs.valid?, "expected valid, got: #{inspect(cs.errors)}"
    end

    test "blank wallet string is normalized to nil so unique-constraint stays clean" do
      cs =
        KiteAgent.changeset(%KiteAgent{}, %{
          "name" => "Free Trader",
          "agent_type" => "trading",
          "organization_id" => @org_id,
          "attestations_enabled" => false,
          "wallet_address" => ""
        })

      assert cs.valid?
      assert get_field(cs, :wallet_address) == nil
    end
  end

  describe "profile_changeset/2 — flipping attestations on later" do
    test "rejects flipping attestations ON without a wallet" do
      agent = %KiteAgent{name: "Existing", agent_type: "trading", attestations_enabled: false}

      cs = KiteAgent.profile_changeset(agent, %{"attestations_enabled" => true})

      refute cs.valid?
      assert {"is required when attestations are enabled", _} = cs.errors[:wallet_address]
    end

    test "accepts flipping attestations ON together with a wallet" do
      agent = %KiteAgent{name: "Existing", agent_type: "trading", attestations_enabled: false}

      cs =
        KiteAgent.profile_changeset(agent, %{
          "attestations_enabled" => true,
          "wallet_address" => @valid_wallet
        })

      assert cs.valid?
      assert get_field(cs, :attestations_enabled) == true
      assert get_field(cs, :wallet_address) == @valid_wallet
    end

    test "accepts flipping attestations OFF on an agent that previously had a wallet" do
      agent = %KiteAgent{
        name: "Existing",
        agent_type: "trading",
        attestations_enabled: true,
        wallet_address: @valid_wallet
      }

      cs = KiteAgent.profile_changeset(agent, %{"attestations_enabled" => false})

      assert cs.valid?
      assert get_field(cs, :attestations_enabled) == false
    end
  end

  defp get_field(cs, field), do: Ecto.Changeset.get_field(cs, field)
end
