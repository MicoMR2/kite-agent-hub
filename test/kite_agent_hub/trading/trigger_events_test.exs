defmodule KiteAgentHub.Trading.TriggerEventsTest do
  use KiteAgentHub.DataCase, async: true

  alias KiteAgentHub.Trading.{TriggerEvent, TriggerEvents, KiteAgent}
  alias KiteAgentHub.Repo

  setup do
    {:ok, org} =
      Repo.insert(
        KiteAgentHub.Orgs.Organization.changeset(
          %KiteAgentHub.Orgs.Organization{},
          %{name: "test org", slug: "test-org-#{System.unique_integer([:positive])}"}
        )
      )

    {:ok, agent} =
      %KiteAgent{}
      |> KiteAgent.changeset(%{
        "name" => "trigger-test",
        "organization_id" => org.id,
        "status" => "active",
        "agent_type" => "trading"
      })
      |> Repo.insert()

    %{agent: agent}
  end

  describe "emit/3" do
    test "inserts a pending trigger_event row", %{agent: agent} do
      payload = %{"market" => "AAPL", "side" => "long", "action" => "buy", "contracts" => 5}

      assert {:ok, %TriggerEvent{} = ev} =
               TriggerEvents.emit(agent, "trade_intent", payload)

      assert ev.status == "pending"
      assert ev.payload == payload
      assert ev.agent_id == agent.id
      assert is_binary(ev.idempotency_key)
    end

    test "idempotent — same payload twice collapses to a single row", %{agent: agent} do
      payload = %{"market" => "AAPL", "side" => "long", "action" => "buy"}

      assert {:ok, _} = TriggerEvents.emit(agent, "trade_intent", payload)
      assert {:error, :duplicate} = TriggerEvents.emit(agent, "trade_intent", payload)
    end

    test "key ordering doesn't break idempotency", %{agent: agent} do
      a = %{"market" => "AAPL", "side" => "long"}
      b = %{"side" => "long", "market" => "AAPL"}

      assert {:ok, _} = TriggerEvents.emit(agent, "trade_intent", a)
      assert {:error, :duplicate} = TriggerEvents.emit(agent, "trade_intent", b)
    end

    test "rejects payload that contains a credential-shaped key", %{agent: agent} do
      payload = %{"api_key" => "sk-prod-abc123", "market" => "AAPL"}

      assert {:error, %Ecto.Changeset{} = cs} =
               TriggerEvents.emit(agent, "trade_intent", payload)

      assert {msg, _} = cs.errors[:payload]
      assert msg =~ "credential"
    end

    test "rejects payload above the 16KB cap", %{agent: agent} do
      big = String.duplicate("a", 17_000)
      payload = %{"market" => "AAPL", "notes" => big}

      assert {:error, %Ecto.Changeset{} = cs} =
               TriggerEvents.emit(agent, "trade_intent", payload)

      assert {msg, _} = cs.errors[:payload]
      assert msg =~ "exceeds"
    end
  end

  describe "pending_for_agent/1 and mark_delivered/1" do
    test "returns only pending rows in insertion order; mark_delivered flips status", %{
      agent: agent
    } do
      {:ok, e1} = TriggerEvents.emit(agent, "trade_intent", %{"market" => "AAPL", "n" => 1})
      {:ok, e2} = TriggerEvents.emit(agent, "trade_intent", %{"market" => "AAPL", "n" => 2})

      assert [%{id: id1}, %{id: id2}] = TriggerEvents.pending_for_agent(agent.id)
      assert id1 == e1.id and id2 == e2.id

      {:ok, e1_d} = TriggerEvents.mark_delivered(e1)
      assert e1_d.status == "delivered"
      assert e1_d.delivered_at

      assert [%{id: ^id2}] = TriggerEvents.pending_for_agent(agent.id)

      # idempotent — calling again on an already-delivered row is a noop.
      assert {:ok, ^e1_d} = TriggerEvents.mark_delivered(e1_d)
    end
  end
end
