defmodule KiteAgentHubWeb.API.TriggersControllerTest do
  use KiteAgentHubWeb.ConnCase, async: false

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TriggerEvent
  alias KiteAgentHub.Trading.TriggerEvents

  setup do
    %{user: user, org: org, agent: agent} = agent_scope_fixture()
    agent = Repo.reload!(agent)
    %{user: user, org: org, agent: agent}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp insert_event!(agent, attrs \\ %{}) do
    base = %{
      symbol: "AAPL",
      side: "buy",
      qty: 10
    }

    {:ok, event} = TriggerEvents.emit(agent, "trade_intent", Map.merge(base, attrs))
    event
  end

  describe "GET /api/v1/triggers/pending — auth" do
    test "401 without Authorization header", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/triggers/pending")
      assert json_response(conn, 401)["error"] == "invalid api key"
    end

    test "401 on malformed Authorization scheme", %{conn: conn, agent: agent} do
      conn =
        conn
        |> put_req_header("authorization", "Token " <> agent.api_token)
        |> get(~p"/api/v1/triggers/pending")

      assert json_response(conn, 401)["error"] == "invalid api key"
    end

    test "401 on unknown token", %{conn: conn} do
      conn =
        conn
        |> auth("not_a_real_token")
        |> get(~p"/api/v1/triggers/pending")

      assert json_response(conn, 401)["error"] == "invalid api key"
    end
  end

  describe "GET /api/v1/triggers/pending — response shape" do
    test "200 with whitelisted fields only, no raw payload leak", %{conn: conn, agent: agent} do
      event = insert_event!(agent, %{symbol: "MSFT", side: "buy", qty: 7})

      resp =
        conn
        |> auth(agent.api_token)
        |> get(~p"/api/v1/triggers/pending")
        |> json_response(200)

      assert resp["ok"] == true
      assert [serialized] = resp["events"]

      # Allowlist parity with CyberSec ask 3 (msg 9123).
      expected_keys = ~w(id event_type symbol side qty idempotency_key created_at)
      assert Enum.sort(Map.keys(serialized)) == Enum.sort(expected_keys)

      assert serialized["id"] == event.id
      assert serialized["symbol"] == "MSFT"
      assert serialized["side"] == "buy"
      assert serialized["qty"] == 7

      # Raw payload jsonb MUST NOT appear at any level of the response.
      refute Map.has_key?(serialized, "payload")
      refute Map.has_key?(resp, "payload")
    end

    test "200 with [] after long-poll timeout when nothing pending", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent.api_token)
        |> get(~p"/api/v1/triggers/pending")
        |> json_response(200)

      assert resp == %{"ok" => true, "events" => []}
    end
  end

  describe "claim_pending_for_agent/1 — idempotency under concurrent polls (CS ask 4)" do
    test "two parallel claims surface the event exactly once", %{agent: agent} do
      insert_event!(agent)

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> TriggerEvents.claim_pending_for_agent(agent.id) end)
        end

      results = Task.await_many(tasks, 5_000)

      total_claimed = results |> Enum.map(&length/1) |> Enum.sum()
      assert total_claimed == 1
    end
  end

  describe "POST /api/v1/triggers/:id/ack" do
    test "404 on cross-agent ack — never 403 (CS ask 5)", %{conn: conn, agent: agent_a} do
      event = insert_event!(agent_a)
      %{agent: agent_b} = agent_scope_fixture()
      agent_b = Repo.reload!(agent_b)

      conn =
        conn
        |> auth(agent_b.api_token)
        |> post(~p"/api/v1/triggers/#{event.id}/ack")

      assert json_response(conn, 404)["error"] == "not_found"

      # Event row must be unchanged — no state leak.
      assert %TriggerEvent{} = reloaded = Repo.get!(TriggerEvent, event.id)
      assert reloaded.status == event.status
      assert reloaded.delivered_at == event.delivered_at
    end

    test "401 without Authorization", %{conn: conn, agent: agent} do
      event = insert_event!(agent)
      conn = post(conn, ~p"/api/v1/triggers/#{event.id}/ack")
      assert json_response(conn, 401)["error"] == "invalid api key"
    end

    test "204 on same-agent ack of a known event", %{conn: conn, agent: agent} do
      event = insert_event!(agent)

      conn =
        conn
        |> auth(agent.api_token)
        |> post(~p"/api/v1/triggers/#{event.id}/ack")

      assert response(conn, 204)
    end

    test "404 on unknown event id, no existence leak", %{conn: conn, agent: agent} do
      bogus = Ecto.UUID.generate()

      conn =
        conn
        |> auth(agent.api_token)
        |> post(~p"/api/v1/triggers/#{bogus}/ack")

      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "PubSub wake (CS ask 6 + Phorari 9126)" do
    test "an emit during long-poll wakes the waiter before the timeout", %{
      conn: conn,
      agent: agent
    } do
      # Bump long-poll high enough that timeout doesn't fire before the
      # emit lands, but low enough that the test fails fast if the
      # broadcast never reaches the waiter.
      prior = Application.get_env(:kite_agent_hub, :triggers_long_poll_ms, 10_000)
      Application.put_env(:kite_agent_hub, :triggers_long_poll_ms, 2_000)
      on_exit(fn -> Application.put_env(:kite_agent_hub, :triggers_long_poll_ms, prior) end)

      poller =
        Task.async(fn ->
          conn
          |> auth(agent.api_token)
          |> get(~p"/api/v1/triggers/pending")
          |> json_response(200)
        end)

      # Give the controller a moment to subscribe before we broadcast.
      Process.sleep(100)
      insert_event!(agent)

      resp = Task.await(poller, 5_000)
      assert resp["ok"] == true
      assert [serialized] = resp["events"]
      assert serialized["symbol"] == "AAPL"
    end
  end
end
