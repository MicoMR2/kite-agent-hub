defmodule KiteAgentHub.Trading.ChainChangeTest do
  use KiteAgentHub.DataCase, async: false

  alias KiteAgentHub.Audit.AuditLog
  alias KiteAgentHub.Kite.ChainId
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading
  alias KiteAgentHub.Trading.KiteAgent

  @testnet 2368
  @mainnet 2366

  setup do
    {:ok, org} =
      Repo.insert(
        KiteAgentHub.Orgs.Organization.changeset(
          %KiteAgentHub.Orgs.Organization{},
          %{name: "t", slug: "t-#{System.unique_integer([:positive])}"}
        )
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(%{
        "name" => "chain-test",
        "organization_id" => org.id,
        "status" => "active",
        "agent_type" => "trading",
        "chain_id" => @testnet
      })
      |> Repo.insert()

    %{agent: agent, org: org}
  end

  describe "KiteAgent.chain_changeset/2" do
    test "accepts testnet and mainnet chain ids", %{agent: agent} do
      for chain <- [@testnet, @mainnet] do
        cs = KiteAgent.chain_changeset(agent, %{"chain_id" => chain})
        assert cs.valid?, inspect(cs.errors)
      end
    end

    test "rejects nil", %{agent: agent} do
      cs = KiteAgent.chain_changeset(agent, %{"chain_id" => nil})
      refute cs.valid?
      assert cs.errors[:chain_id]
    end

    test "rejects unknown chain ids", %{agent: agent} do
      cs = KiteAgent.chain_changeset(agent, %{"chain_id" => 12345})
      refute cs.valid?
      assert cs.errors[:chain_id]
    end
  end

  describe "Trading.update_agent_chain/3" do
    test "transitions agent.chain_id and writes audit row on flip", %{agent: agent} do
      assert {:ok, updated} = Trading.update_agent_chain(agent, %{"chain_id" => @mainnet}, 42)
      assert updated.chain_id == @mainnet

      [row] = Repo.all(AuditLog)
      assert row.action == "agent_chain_changed"
      assert row.target_type == "kite_agent"
      assert row.target_id == agent.id
      assert row.metadata == %{"from" => @testnet, "to" => @mainnet}
      assert row.actor_user_id == "42"
    end

    test "no-op save does NOT write an audit row (CS ask 6 only-on-transition)", %{agent: agent} do
      assert {:ok, _} = Trading.update_agent_chain(agent, %{"chain_id" => @testnet}, 42)
      assert Repo.aggregate(AuditLog, :count) == 0
    end

    test "returns {:error, changeset} on invalid chain_id; no audit row", %{agent: agent} do
      assert {:error, %Ecto.Changeset{}} =
               Trading.update_agent_chain(agent, %{"chain_id" => 99}, 42)

      assert Repo.aggregate(AuditLog, :count) == 0
    end
  end

  describe "ChainId.mainnet_available?/0" do
    test "false when env unset" do
      prior = Application.get_env(:kite_agent_hub, :agent_private_key_mainnet)
      Application.delete_env(:kite_agent_hub, :agent_private_key_mainnet)
      on_exit(fn -> if prior, do: Application.put_env(:kite_agent_hub, :agent_private_key_mainnet, prior) end)

      # Also bypass System.get_env fallback.
      System.delete_env("AGENT_PRIVATE_KEY_MAINNET")

      refute ChainId.mainnet_available?()
    end

    test "true when env set" do
      Application.put_env(:kite_agent_hub, :agent_private_key_mainnet, "0xfake_signing_key")
      on_exit(fn -> Application.delete_env(:kite_agent_hub, :agent_private_key_mainnet) end)

      assert ChainId.mainnet_available?()
    end
  end
end
