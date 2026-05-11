defmodule KiteAgentHub.Accounts.AgentPassportLinkTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Accounts.AgentPassportLink
  alias KiteAgentHub.Trading.KiteAgent
  alias KiteAgentHub.Repo

  setup do
    {:ok, org} =
      Repo.insert(
        KiteAgentHub.Orgs.Organization.changeset(
          %KiteAgentHub.Orgs.Organization{},
          %{name: "test org", slug: "test-org-#{System.unique_integer([:positive])}"}
        )
      )

    # The kite_agents row goes through Trading.create_agent in app code,
    # which sets RLS context. For tests we cast directly through the
    # schema since the changeset is what we want to exercise.
    attrs = %{
      "name" => "test-agent",
      "organization_id" => org.id,
      "status" => "active",
      "agent_type" => "trading"
    }

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(attrs)
      |> Repo.insert()

    %{agent: agent}
  end

  test "valid link inserts", %{agent: agent} do
    attrs = %{
      agent_id: agent.id,
      passport_user_id: "user_abc",
      passport_agent_id: "agent_xyz",
      passport_wallet_address: "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"
    }

    assert {:ok, link} =
             %AgentPassportLink{}
             |> AgentPassportLink.changeset(attrs)
             |> Repo.insert()

    assert link.active
    assert link.linked_at
  end

  test "wallet must be a 0x-prefixed 40-hex address", %{agent: agent} do
    cs =
      AgentPassportLink.changeset(%AgentPassportLink{}, %{
        agent_id: agent.id,
        passport_user_id: "u",
        passport_agent_id: "a",
        passport_wallet_address: "not-an-address"
      })

    refute cs.valid?
    assert {"must be a 0x-prefixed 40-hex-character EVM address", _} =
             cs.errors[:passport_wallet_address]
  end

  test "second active link for same agent rejected by partial unique index", %{agent: agent} do
    valid_attrs = %{
      agent_id: agent.id,
      passport_user_id: "u",
      passport_agent_id: "a",
      passport_wallet_address: "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"
    }

    assert {:ok, _first} =
             AgentPassportLink.changeset(%AgentPassportLink{}, valid_attrs)
             |> Repo.insert()

    assert {:error, cs} =
             AgentPassportLink.changeset(%AgentPassportLink{}, valid_attrs)
             |> Repo.insert()

    assert {"agent already has an active passport link", _} = cs.errors[:agent_id]
  end

  test "soft-deactivated row lets new active link land", %{agent: agent} do
    valid_attrs = %{
      agent_id: agent.id,
      passport_user_id: "u",
      passport_agent_id: "a",
      passport_wallet_address: "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"
    }

    {:ok, first} =
      AgentPassportLink.changeset(%AgentPassportLink{}, valid_attrs)
      |> Repo.insert()

    {:ok, _} =
      first
      |> AgentPassportLink.changeset(%{active: false})
      |> Repo.update()

    assert {:ok, _second} =
             AgentPassportLink.changeset(%AgentPassportLink{}, valid_attrs)
             |> Repo.insert()
  end
end
