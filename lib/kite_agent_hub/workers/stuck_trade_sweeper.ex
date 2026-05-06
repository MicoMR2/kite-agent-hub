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
      run_for_agent(agent_id, owner_user_id, cutoff)
    end)

    :ok
  end

  # Two-phase split (mirrors AlpacaSettlementWorker, PR #301):
  #   Phase 1 (with_user): auto-cancel stuck rows in DB + load creds.
  #   Phase 2 (no DB lock): per-trade Alpaca cancel HTTP fan-out.
  # Broker errors only log a warning, so no Phase 3 DB writes are needed.
  defp run_for_agent(agent_id, owner_user_id, cutoff) do
    case sweep_phase1(agent_id, owner_user_id, cutoff) do
      :noop ->
        :ok

      {:no_alpaca_targets, _count} ->
        :ok

      {:no_creds, reason} ->
        Logger.warning(
          "StuckTradeSweeper: agent #{agent_id} — alpaca credentials unavailable, skipping broker cancels: #{inspect(reason)}"
        )

      {:targets, alpaca_trades, {key_id, secret, env}} ->
        # HTTP fan-out runs after the with_user block closes.
        Enum.each(alpaca_trades, fn t ->
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
    end
  end

  defp sweep_phase1(agent_id, owner_user_id, cutoff) do
    Repo.with_user(owner_user_id, fn ->
      case Trading.auto_cancel_stuck_trades(cutoff, agent_id: agent_id) do
        {0, _} ->
          :noop

        {count, trades} ->
          Logger.info(
            "StuckTradeSweeper: agent #{agent_id} — auto-cancelled #{count} stuck trade(s)"
          )

          alpaca_trades =
            Enum.filter(trades, fn t ->
              t.platform == "alpaca" and is_binary(t.platform_order_id) and
                t.platform_order_id != ""
            end)

          case alpaca_trades do
            [] ->
              {:no_alpaca_targets, count}

            targets ->
              agent = Trading.get_agent!(agent_id)

              case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
                {:ok, creds} -> {:targets, targets, creds}
                {:error, reason} -> {:no_creds, reason}
              end
          end
      end
    end)
  end
end
