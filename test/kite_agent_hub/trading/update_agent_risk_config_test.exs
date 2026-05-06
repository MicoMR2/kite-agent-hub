defmodule KiteAgentHub.Trading.UpdateAgentRiskConfigTest do
  @moduledoc """
  Confirms `Trading.update_agent_risk_config/3` writes the agent
  update + audit row in a single transaction, and rolls back cleanly
  on validation failure.
  """

  use KiteAgentHub.DataCase, async: true

  import KiteAgentHub.TradingFixtures
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading
  alias KiteAgentHub.Trading.AgentConfigChange

  describe "update_agent_risk_config/3" do
    test "happy path: persists config and writes one audit row" do
      %{user: user, agent: agent} = agent_scope_fixture()

      attrs = %{"risk_config" => %{"per_trade_notional_cap_usd" => "1500"}}

      assert {:ok, {:ok, updated}} =
               Repo.with_user(user.id, fn ->
                 Trading.update_agent_risk_config(agent, attrs, user.id)
               end)

      assert updated.risk_config["per_trade_notional_cap_usd"] == "1500"

      assert [audit] = Repo.all(AgentConfigChange)
      assert audit.agent_id == agent.id
      assert audit.user_id == user.id
      assert audit.prev_config == %{}
      assert audit.new_config["per_trade_notional_cap_usd"] == "1500"
    end

    test "invalid value rolls back both the agent update and the audit insert" do
      %{user: user, agent: agent} = agent_scope_fixture()

      assert {:ok, {:error, %Ecto.Changeset{}}} =
               Repo.with_user(user.id, fn ->
                 Trading.update_agent_risk_config(
                   agent,
                   %{"risk_config" => %{"per_trade_notional_cap_usd" => "9999"}},
                   user.id
                 )
               end)

      reloaded = Trading.get_agent!(agent.id)
      assert reloaded.risk_config == %{}
      assert Repo.aggregate(AgentConfigChange, :count, :id) == 0
    end

    test "second save records the prior config as prev_config" do
      %{user: user, agent: agent} = agent_scope_fixture()

      {:ok, {:ok, agent}} =
        Repo.with_user(user.id, fn ->
          Trading.update_agent_risk_config(
            agent,
            %{"risk_config" => %{"per_trade_notional_cap_usd" => "1000"}},
            user.id
          )
        end)

      {:ok, {:ok, _agent2}} =
        Repo.with_user(user.id, fn ->
          Trading.update_agent_risk_config(
            agent,
            %{"risk_config" => %{"per_trade_notional_cap_usd" => "2000"}},
            user.id
          )
        end)

      [first, second] = Repo.all(from(a in AgentConfigChange, order_by: [asc: :inserted_at]))

      assert first.prev_config == %{}
      assert first.new_config["per_trade_notional_cap_usd"] == "1000"
      assert second.prev_config["per_trade_notional_cap_usd"] == "1000"
      assert second.new_config["per_trade_notional_cap_usd"] == "2000"
    end
  end
end
