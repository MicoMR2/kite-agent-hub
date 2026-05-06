defmodule KiteAgentHub.Workers.PaperExecutionWorkerRiskGateTest do
  @moduledoc """
  Mirror of TradeExecutionWorker risk-gate coverage for the paper
  worker. Paper providers compute notional differently per venue
  (forex base-units vs Kalshi cents-per-contract), so over-cap
  enforcement is intentionally NOT done here — but the
  fail-closed `:invalid_risk_config` semantic mirrors. A corrupted
  risk_config row stops both live and paper trading.
  """

  use KiteAgentHub.DataCase, async: false

  import KiteAgentHub.TradingFixtures
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Workers.PaperExecutionWorker

  defp setup_agent_with_risk_config(risk_config) do
    %{user: user, agent: agent} =
      agent_scope_fixture(%{
        agent_type: "trading",
        status: "active"
      })

    {:ok, agent} =
      agent
      |> Ecto.Changeset.change(%{risk_config: risk_config})
      |> Repo.update()

    %{user: user, agent: agent}
  end

  defp build_job(agent_id, args) do
    %Oban.Job{id: 1, args: Map.put(args, "agent_id", agent_id)}
  end

  describe "RC-INVALID gate" do
    test "blocks Kalshi paper dispatch with status=failed + RC-INVALID prefix" do
      %{user: user, agent: agent} =
        setup_agent_with_risk_config(%{"per_trade_notional_cap_usd" => "9999"})

      args = %{
        "provider" => "kalshi",
        "symbol" => "TRUMPWIN-2024",
        "side" => "buy",
        "units" => 1,
        "yes_price" => 50
      }

      Repo.with_user(user.id, fn ->
        PaperExecutionWorker.perform(build_job(agent.id, args))
      end)

      [trade] =
        Repo.all(
          from t in TradeRecord, where: t.kite_agent_id == ^agent.id, order_by: [desc: t.id]
        )

      assert trade.status == "failed"
      assert trade.platform == "kalshi"
      assert trade.reason =~ "RC-INVALID"
    end

    test "blocks OANDA paper dispatch with status=failed + RC-INVALID prefix" do
      %{user: user, agent: agent} =
        setup_agent_with_risk_config(%{"per_trade_notional_cap_usd" => "9999"})

      args = %{
        "provider" => "oanda_practice",
        "symbol" => "EUR_USD",
        "side" => "buy",
        "units" => 1000
      }

      Repo.with_user(user.id, fn ->
        PaperExecutionWorker.perform(build_job(agent.id, args))
      end)

      [trade] =
        Repo.all(
          from t in TradeRecord, where: t.kite_agent_id == ^agent.id, order_by: [desc: t.id]
        )

      assert trade.status == "failed"
      assert trade.platform == "oanda"
      assert trade.reason =~ "RC-INVALID"
    end
  end
end
