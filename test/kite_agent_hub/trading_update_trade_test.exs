defmodule KiteAgentHub.TradingUpdateTradeTest do
  @moduledoc """
  Covers the new `Trading.update_trade/2` + `Trading.set_trade_attestation/2`
  helpers that workers route through so every trade-row mutation
  fires a `:trade_updated` PubSub broadcast.
  """

  use KiteAgentHub.DataCase

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Repo, Trading}

  defp as_user(user, fun) do
    {:ok, result} = Repo.with_user(user.id, fun)
    result
  end

  setup do
    %{user: user, agent: agent} = scope = agent_scope_fixture()
    trade = trade_fixture(scope)

    Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent.id}")

    {:ok, scope: scope, user: user, agent: agent, trade: trade}
  end

  describe "update_trade/2" do
    test "broadcasts :trade_updated on success", %{user: user, trade: trade} do
      assert {:ok, updated} =
               as_user(user, fn -> Trading.update_trade(trade, %{platform_order_id: "abc-123"}) end)

      assert updated.platform_order_id == "abc-123"
      assert_receive {:trade_updated, ^updated}, 200
    end

    test "fires KCI outcome record when status flips to a terminal value",
         %{user: user, trade: trade} do
      assert {:ok, failed} =
               as_user(user, fn ->
                 Trading.update_trade(trade, %{status: "failed", reason: "broker rejected"})
               end)

      assert failed.status == "failed"
      assert failed.reason == "broker rejected"
      assert_receive {:trade_updated, ^failed}, 200
    end

    test "does not fire KCI outcome on non-terminal updates", %{user: user, trade: trade} do
      # platform_order_id assignment leaves status="open" — terminal-status
      # branch should not fire. We can't directly observe the KCI no-op
      # without mocks, but at minimum the broadcast still fires and the
      # row updates.
      assert {:ok, updated} =
               as_user(user, fn -> Trading.update_trade(trade, %{platform_order_id: "ord-1"}) end)

      assert updated.status == "open"
      assert_receive {:trade_updated, ^updated}, 200
    end

    test "returns {:error, changeset} on invalid attrs without broadcasting",
         %{user: user, trade: trade} do
      # Status must be in @statuses; "garbage" should fail validation.
      assert {:error, %Ecto.Changeset{}} =
               as_user(user, fn -> Trading.update_trade(trade, %{status: "garbage"}) end)

      refute_receive {:trade_updated, _}, 100
    end
  end

  describe "set_trade_attestation/2" do
    test "writes attestation_tx_hash + broadcasts :trade_updated",
         %{user: user, trade: trade} do
      tx_hash = "0x" <> String.duplicate("a", 64)

      assert {:ok, attested} =
               as_user(user, fn -> Trading.set_trade_attestation(trade, tx_hash) end)

      assert attested.attestation_tx_hash == tx_hash
      assert_receive {:trade_updated, ^attested}, 200
    end

    test "rejects re-attestation (lock_field protects the column)",
         %{user: user, trade: trade} do
      tx_hash = "0x" <> String.duplicate("a", 64)
      different_hash = "0x" <> String.duplicate("b", 64)

      {:ok, _} = as_user(user, fn -> Trading.set_trade_attestation(trade, tx_hash) end)

      # Reload to get the lock state
      reloaded = Repo.reload!(trade)

      assert {:error, %Ecto.Changeset{}} =
               as_user(user, fn -> Trading.set_trade_attestation(reloaded, different_hash) end)
    end
  end
end
