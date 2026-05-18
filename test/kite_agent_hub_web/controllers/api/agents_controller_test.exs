defmodule KiteAgentHubWeb.API.AgentsControllerTest do
  use KiteAgentHubWeb.ConnCase, async: true

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.Repo

  setup do
    %{agent: agent} = agent_scope_fixture()
    {:ok, agent: Repo.reload!(agent)}
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  describe "PATCH /api/v1/agents/:id" do
    test "401 without bearer", %{conn: conn, agent: agent} do
      conn = patch(conn, ~p"/api/v1/agents/#{agent.id}", %{name: "new"})
      assert json_response(conn, 401)["ok"] == false
    end

    test "403 when URL id mismatches bearer", %{conn: conn, agent: agent} do
      %{agent: other} = agent_scope_fixture()
      other = Repo.reload!(other)

      conn =
        conn
        |> auth(other.api_token)
        |> patch(~p"/api/v1/agents/#{agent.id}", %{name: "hijack"})

      assert json_response(conn, 403)["error"] == "agent mismatch"
    end

    test "updates name/tags/bio and returns 200", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent.api_token)
        |> patch(~p"/api/v1/agents/#{agent.id}", %{
          name: "Updated Name",
          tags: ["momentum", "equities"],
          bio: "Scalps breakouts."
        })
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["agent"]["name"] == "Updated Name"
      assert resp["agent"]["tags"] == ["momentum", "equities"]
      assert resp["agent"]["bio"] == "Scalps breakouts."
      refute Map.has_key?(resp["agent"], "api_token")
    end

    test "drops api_token/wallet_address/status/organization_id from the request body", %{
      conn: conn,
      agent: agent
    } do
      resp =
        conn
        |> auth(agent.api_token)
        |> patch(~p"/api/v1/agents/#{agent.id}", %{
          name: "ok",
          api_token: "hijacked_token",
          wallet_address: "0x0000000000000000000000000000000000000000",
          status: "archived",
          organization_id: Ecto.UUID.generate()
        })
        |> json_response(200)

      reloaded = Repo.reload!(agent)

      assert reloaded.api_token == agent.api_token
      assert reloaded.status == agent.status
      assert reloaded.organization_id == agent.organization_id
      assert resp["agent"]["status"] == agent.status
    end

    test "422 on invalid tags (too long)", %{conn: conn, agent: agent} do
      huge = String.duplicate("a", 100)

      resp =
        conn
        |> auth(agent.api_token)
        |> patch(~p"/api/v1/agents/#{agent.id}", %{name: "ok", tags: [huge]})
        |> json_response(422)

      assert resp["ok"] == false
      assert resp["errors"]["tags"] != nil
    end
  end

  describe "POST /api/v1/agents/:id/rotate_token" do
    test "401 without bearer", %{conn: conn, agent: agent} do
      conn = post(conn, ~p"/api/v1/agents/#{agent.id}/rotate_token", %{})
      assert json_response(conn, 401)["ok"] == false
    end

    test "403 when URL id mismatches bearer", %{conn: conn, agent: agent} do
      %{agent: other} = agent_scope_fixture()
      other = Repo.reload!(other)

      conn =
        conn
        |> auth(other.api_token)
        |> post(~p"/api/v1/agents/#{agent.id}/rotate_token", %{})

      assert json_response(conn, 403)["error"] == "agent mismatch"
    end

    test "rotates token, returns new value once, old token stops working", %{
      conn: conn,
      agent: agent
    } do
      resp =
        conn
        |> auth(agent.api_token)
        |> post(~p"/api/v1/agents/#{agent.id}/rotate_token", %{})
        |> json_response(200)

      new_token = resp["agent"]["api_token"]
      assert is_binary(new_token)
      assert new_token != agent.api_token
      assert String.starts_with?(new_token, "kite_")

      # Old token should now fail.
      replay =
        build_conn()
        |> auth(agent.api_token)
        |> post(~p"/api/v1/agents/#{agent.id}/rotate_token", %{})

      assert json_response(replay, 401)
    end
  end

  describe "DELETE /api/v1/agents/:id" do
    test "401 without bearer", %{conn: conn, agent: agent} do
      conn = delete(conn, ~p"/api/v1/agents/#{agent.id}")
      assert json_response(conn, 401)["ok"] == false
    end

    test "403 when URL id mismatches bearer", %{conn: conn, agent: agent} do
      %{agent: other} = agent_scope_fixture()
      other = Repo.reload!(other)

      conn =
        conn
        |> auth(other.api_token)
        |> delete(~p"/api/v1/agents/#{agent.id}")

      assert json_response(conn, 403)["error"] == "agent mismatch"
    end

    test "flips status to archived and stops the agent", %{conn: conn, agent: agent} do
      resp =
        conn
        |> auth(agent.api_token)
        |> delete(~p"/api/v1/agents/#{agent.id}")
        |> json_response(200)

      assert resp["ok"] == true
      assert resp["agent"]["status"] == "archived"
      assert resp["cancelled_open_trades"] == 0

      assert Repo.reload!(agent).status == "archived"
    end
  end

  describe "rate limiting (F4 audit fix)" do
    test "11th rapid PATCH /agents/:id is 429", %{conn: conn, agent: agent} do
      # The RateLimiter caps each agent at 10 writes per 1s bucket.
      # Hammer PATCH (token stays stable, unlike rotate_token which
      # would invalidate the bearer on each call). Confirm the 11th
      # call is rejected with 429 + the consistent error shape.
      results =
        for i <- 1..11 do
          conn
          |> auth(agent.api_token)
          |> patch(~p"/api/v1/agents/#{agent.id}", %{name: "Burst #{i}"})
        end

      statuses = Enum.map(results, & &1.status)
      ok_count = Enum.count(statuses, &(&1 == 200))
      throttled_count = Enum.count(statuses, &(&1 == 429))

      assert ok_count >= 10, "first 10 writes in the bucket should succeed"
      assert throttled_count >= 1, "expected at least one 429 within the 11-call burst"

      throttled = Enum.find(results, &(&1.status == 429))
      body = Jason.decode!(throttled.resp_body)
      assert body["error"] == "rate limited"
    end
  end
end
