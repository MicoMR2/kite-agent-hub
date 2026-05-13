defmodule KiteAgentHub.Workers.TradeExecutionWorkerRiskGateTest do
  @moduledoc """
  Confirms the risk gate added in #297 short-circuits the worker
  before any broker call:

    * Invalid `risk_config` row → trade record persisted with
      `status: "failed"` + `reason` prefixed `RC-INVALID:`.
    * Notional above `Trading.Risk.per_trade_notional_cap/1` →
      trade record persisted with `status: "failed"` + `reason`
      prefixed `RC-CAP:`.

  The cap-resolved happy path is not exercised here because it
  would hit `maybe_execute_on_platform/4` and require either a
  broker mock or live credentials. The Trading.Risk unit suite
  covers the decision logic; what this file proves is that the
  worker correctly translates each Risk return into the right
  `trade_records` row shape and emits the RC-prefixed reason.
  """

  use KiteAgentHub.DataCase, async: false

  import KiteAgentHub.TradingFixtures
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Workers.TradeExecutionWorker

  defp setup_agent_with_risk_config(risk_config) do
    %{user: user, agent: agent} =
      agent_scope_fixture(%{
        agent_type: "trading",
        status: "active"
      })

    # Bypass the changeset whitelist on purpose — the gate must
    # fail-closed even on rows that were edited manually in psql or
    # predate the validator.
    {:ok, agent} =
      agent
      |> Ecto.Changeset.change(%{risk_config: risk_config})
      |> Repo.update()

    %{user: user, agent: agent}
  end

  defp build_job(agent_id, args) do
    %Oban.Job{args: Map.put(args, "agent_id", agent_id)}
  end

  defp default_args do
    %{
      "market" => "ETH-USDC",
      "side" => "long",
      "action" => "buy",
      "fill_price" => "100",
      "notional" => "200"
    }
  end

  describe "RC-INVALID gate" do
    test "above-ceiling cap (manually set in DB) blocks the trade with RC-INVALID" do
      %{user: user, agent: agent} =
        setup_agent_with_risk_config(%{"per_trade_notional_cap_usd" => "9999"})

      job = build_job(agent.id, default_args())

      Repo.with_user(user.id, fn -> TradeExecutionWorker.perform(job) end)

      [trade] =
        Repo.all(
          from t in TradeRecord, where: t.kite_agent_id == ^agent.id, order_by: [desc: t.id]
        )

      assert trade.status == "failed"
      assert trade.reason =~ "RC-INVALID"
      refute trade.reason =~ "RC-CAP"
    end
  end

  describe "RC-CAP gate" do
    test "notional > cap blocks the trade with RC-CAP" do
      %{user: user, agent: agent} =
        setup_agent_with_risk_config(%{"per_trade_notional_cap_usd" => "100"})

      # Notional 200 > cap 100.
      job =
        build_job(agent.id, %{
          "market" => "ETH-USDC",
          "side" => "long",
          "action" => "buy",
          "fill_price" => "100",
          "notional" => "200"
        })

      Repo.with_user(user.id, fn -> TradeExecutionWorker.perform(job) end)

      [trade] =
        Repo.all(
          from t in TradeRecord, where: t.kite_agent_id == ^agent.id, order_by: [desc: t.id]
        )

      assert trade.status == "failed"
      assert trade.reason =~ "RC-CAP"
      refute trade.reason =~ "RC-INVALID"
    end
  end

  describe "telemetry" do
    test "blocked trade emits :reason_category on the [:kah, :risk_config, :blocked_trade] event" do
      %{user: user, agent: agent} =
        setup_agent_with_risk_config(%{"per_trade_notional_cap_usd" => "9999"})

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "rc-gate-test-#{inspect(ref)}",
        [:kah, :risk_config, :blocked_trade],
        fn _event, _measurements, metadata, _ ->
          send(test_pid, {ref, metadata})
        end,
        nil
      )

      try do
        Repo.with_user(user.id, fn ->
          TradeExecutionWorker.perform(build_job(agent.id, default_args()))
        end)

        assert_receive {^ref, %{reason_category: :invalid, agent_id: id}}, 500
        assert id == agent.id
      after
        :telemetry.detach("rc-gate-test-#{inspect(ref)}")
      end
    end
  end
end
