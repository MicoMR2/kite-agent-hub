defmodule KiteAgentHub.TradingCancelTest do
  use KiteAgentHub.DataCase

  import KiteAgentHub.TradingFixtures

  alias KiteAgentHub.{Repo, Trading}

  # `Repo.with_user/2` wraps `fun` in a transaction and returns
  # `{:ok, result}` — unwrap for readability.
  defp as_user(user, fun) do
    {:ok, result} = Repo.with_user(user.id, fun)
    result
  end

  describe "cancel_trade/2" do
    test "flips an open trade to cancelled for the owning agent" do
      %{user: user, agent: agent} = scope = agent_scope_fixture()
      trade = trade_fixture(scope)

      assert {:ok, cancelled} = as_user(user, fn -> Trading.cancel_trade(trade.id, agent.id) end)
      assert cancelled.status == "cancelled"
      assert cancelled.id == trade.id
    end

    test "is idempotent — re-cancelling returns :already_terminal without a second DB write" do
      %{user: user, agent: agent} = scope = agent_scope_fixture()
      trade = trade_fixture(scope)

      {:ok, _} = as_user(user, fn -> Trading.cancel_trade(trade.id, agent.id) end)

      assert {:ok, :already_terminal, same_trade} =
               as_user(user, fn -> Trading.cancel_trade(trade.id, agent.id) end)

      assert same_trade.status == "cancelled"
    end

    test "returns :not_found for a trade the agent does not own (no existence leak)" do
      scope = agent_scope_fixture()
      trade = trade_fixture(scope)

      %{user: other_user, agent: other_agent} = agent_scope_fixture()

      assert {:error, :not_found} =
               as_user(other_user, fn -> Trading.cancel_trade(trade.id, other_agent.id) end)
    end
  end

  describe "auto_cancel_stuck_trades/1" do
    test "flips open trades older than cutoff to cancelled" do
      %{user: user} = scope = agent_scope_fixture()

      two_hours_ago =
        DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      stuck = trade_fixture(scope, %{inserted_at: two_hours_ago})
      fresh = trade_fixture(scope)

      cutoff =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {count, _trades} = as_user(user, fn -> Trading.auto_cancel_stuck_trades(cutoff) end)

      assert count == 1

      stuck_after = Repo.reload!(stuck)
      fresh_after = Repo.reload!(fresh)

      assert stuck_after.status == "cancelled"
      assert fresh_after.status == "open"
    end

    test "does not touch trades that are already settled or cancelled" do
      %{user: user} = scope = agent_scope_fixture()
      old = DateTime.utc_now() |> DateTime.add(-7200, :second) |> DateTime.truncate(:second)

      settled =
        trade_fixture(scope, %{
          status: "settled",
          inserted_at: old,
          realized_pnl: Decimal.new(1)
        })

      already_cancelled = trade_fixture(scope, %{status: "cancelled", inserted_at: old})
      failed = trade_fixture(scope, %{status: "failed", inserted_at: old})

      cutoff =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      {count, _} = as_user(user, fn -> Trading.auto_cancel_stuck_trades(cutoff) end)

      assert count == 0

      assert Repo.reload!(settled).status == "settled"
      assert Repo.reload!(already_cancelled).status == "cancelled"
      assert Repo.reload!(failed).status == "failed"
    end
  end
end
