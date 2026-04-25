defmodule KiteAgentHub.Workers.StuckTradeSweeper do
  @moduledoc """
  Periodic sweep that auto-cancels any trade with status=`"open"` older
  than `@stuck_after`. Prevents the zombie-order pile-up Test agent hit
  between Apr 8-10: orders that never got a terminal status from the
  broker sat open forever, blocking same-symbol re-entry through
  wash-trade rules.

  Runs every minute via `Oban.Plugins.Cron`. For each active agent we
  re-establish per-agent RLS scope (same pattern as
  `AlpacaSettlementWorker`), sweep that agent's stuck trades, and —
  for Alpaca-platform orders with a `platform_order_id` — forward a
  cancel to the broker so the book clears on both sides. Alpaca's
  cancel endpoint is idempotent (422/404 treated as already-terminal
  by `AlpacaClient.cancel_order/4`), so a re-run after a transient
  failure is safe.

  The DB write happens first; a broker failure only logs a warning.
  Rationale: the hub's view of the trade is authoritative for sizing
  decisions, and leaving a trade open in the DB while we wait for
  Alpaca is exactly the bug we're fixing.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 30, fields: [:worker]]

  require Logger

  alias KiteAgentHub.{Credentials, Repo, Trading}
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  # Trades open longer than this are considered zombies. An hour is
  # comfortably longer than any legitimate day-order settlement window.
  @stuck_after_seconds 3600

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@stuck_after_seconds, :second)
      |> DateTime.truncate(:second)

    agents = Repo.active_agents_with_owners()
    Logger.info("StuckTradeSweeper: scanning #{length(agents)} active agent(s)")

    Enum.each(agents, fn {agent_id, owner_user_id} ->
      Repo.with_user(owner_user_id, fn -> sweep_for_agent(agent_id, cutoff) end)
    end)

    :ok
  end

  defp sweep_for_agent(agent_id, cutoff) do
    case Trading.auto_cancel_stuck_trades(cutoff, agent_id: agent_id) do
      {0, _} ->
        :ok

      {count, trades} ->
        Logger.info(
          "StuckTradeSweeper: agent #{agent_id} — auto-cancelled #{count} stuck trade(s)"
        )

        maybe_cancel_on_broker(trades, agent_id)
    end
  end

  defp maybe_cancel_on_broker(trades, agent_id) do
    alpaca_trades =
      Enum.filter(trades, fn t ->
        t.platform == "alpaca" and is_binary(t.platform_order_id) and t.platform_order_id != ""
      end)

    case alpaca_trades do
      [] ->
        :ok

      alpaca ->
        agent = Trading.get_agent!(agent_id)

        case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
          {:ok, {key_id, secret, env}} ->
            Enum.each(alpaca, fn t ->
              case AlpacaClient.cancel_order(key_id, secret, t.platform_order_id, env) do
                {:ok, result} ->
                  Logger.info(
                    "StuckTradeSweeper: alpaca cancel #{t.platform_order_id} ok (#{inspect(result)})"
                  )

                {:error, reason} ->
                  Logger.warning(
                    "StuckTradeSweeper: alpaca cancel #{t.platform_order_id} failed: #{inspect(reason)}"
                  )
              end
            end)

          {:error, reason} ->
            Logger.warning(
              "StuckTradeSweeper: agent #{agent_id} — alpaca credentials unavailable, skipping broker cancels: #{inspect(reason)}"
            )
        end
    end
  end
end
