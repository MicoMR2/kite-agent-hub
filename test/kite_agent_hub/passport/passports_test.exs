defmodule KiteAgentHub.Passport.PassportsTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Accounts.AgentPassportLink
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Passport.Passports
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.KiteAgent

  @valid_wallet "0xFC74b669CF7c1676feeD4Fea99A8d9fE2FAd3465"

  setup do
    user = insert_user!()

    {:ok, org} =
      Repo.insert(
        Organization.changeset(%Organization{}, %{
          name: "test org",
          slug: "test-org-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, agent} =
      Repo.with_user(user.id, fn ->
        %KiteAgent{}
        |> KiteAgent.changeset(%{
          "name" => "byo-test",
          "organization_id" => org.id,
          "status" => "active",
          "agent_type" => "trading"
        })
        |> Repo.insert()
      end)
      |> unwrap()

    %{user: user, org: org, agent: agent}
  end

  describe "link_agent/3" do
    test "inserts an active link for valid public identifiers", %{user: user, agent: agent} do
      attrs = %{
        "passport_user_id" => "user_abc",
        "passport_agent_id" => "agent_xyz",
        "passport_wallet_address" => @valid_wallet
      }

      assert {:ok, %AgentPassportLink{} = link} = Passports.link_agent(user.id, agent, attrs)
      assert link.active
      assert link.passport_wallet_address == @valid_wallet
    end

    test "rejects JWT-shaped passport_agent_id (2+ dots, >500 bytes)", %{user: user, agent: agent} do
      jwt = "h" <> String.duplicate("a", 200) <> "." <> String.duplicate("b", 200) <> "." <> String.duplicate("c", 200)

      attrs = %{
        "passport_user_id" => "user_abc",
        "passport_agent_id" => jwt,
        "passport_wallet_address" => @valid_wallet
      }

      assert {:error, %Ecto.Changeset{} = cs} = Passports.link_agent(user.id, agent, attrs)
      assert {msg, _} = cs.errors[:passport_agent_id]
      assert msg =~ "credential"
      # CyberSec ask 7: error message must not echo the offending value
      refute msg =~ jwt

      assert Repo.aggregate(AgentPassportLink, :count) == 0
    end

    test "rejects passport_user_id > 256 bytes", %{user: user, agent: agent} do
      attrs = %{
        "passport_user_id" => String.duplicate("u", 257),
        "passport_agent_id" => "a",
        "passport_wallet_address" => @valid_wallet
      }

      assert {:error, cs} = Passports.link_agent(user.id, agent, attrs)
      assert cs.errors[:passport_user_id]
    end

    test "rejects malformed wallet", %{user: user, agent: agent} do
      attrs = %{
        "passport_user_id" => "u",
        "passport_agent_id" => "a",
        "passport_wallet_address" => "not-an-address"
      }

      assert {:error, cs} = Passports.link_agent(user.id, agent, attrs)
      assert cs.errors[:passport_wallet_address]
    end
  end

  describe "unlink_agent/2" do
    test "flips active to false, keeps audit row", %{user: user, agent: agent} do
      {:ok, link} =
        Passports.link_agent(user.id, agent, %{
          "passport_user_id" => "u",
          "passport_agent_id" => "a",
          "passport_wallet_address" => @valid_wallet
        })

      assert {:ok, unlinked} = Passports.unlink_agent(user.id, link)
      refute unlinked.active
      assert Repo.aggregate(AgentPassportLink, :count) == 1
      assert Passports.get_active_link(agent.id) == nil
    end
  end

  describe "change_payment_rail/3" do
    test "persists a valid rail", %{user: user, agent: agent} do
      assert {:ok, updated} = Passports.change_payment_rail(user.id, agent, "per_trade")
      assert updated.payment_rail == "per_trade"
    end

    test "rejects an unknown rail", %{user: user, agent: agent} do
      assert {:error, :invalid_rail} =
               Passports.change_payment_rail(user.id, agent, "free_lunch")
    end
  end

  describe "active_links_by_agent/1" do
    test "returns a map keyed by agent_id for active links only", %{user: user, agent: agent} do
      {:ok, link} =
        Passports.link_agent(user.id, agent, %{
          "passport_user_id" => "u",
          "passport_agent_id" => "a",
          "passport_wallet_address" => @valid_wallet
        })

      agent_id = agent.id
      assert %{^agent_id => ^link} = Passports.active_links_by_agent([agent])

      {:ok, _} = Passports.unlink_agent(user.id, link)
      assert Passports.active_links_by_agent([agent]) == %{}
    end
  end

  defp insert_user! do
    {:ok, user} =
      Repo.insert(
        KiteAgentHub.Accounts.User.email_changeset(%KiteAgentHub.Accounts.User{}, %{
          email: "byo-#{System.unique_integer([:positive])}@example.com"
        })
      )

    user
  end

  defp unwrap({:ok, {:ok, value}}), do: {:ok, value}
  defp unwrap({:ok, value}), do: {:ok, value}
end
