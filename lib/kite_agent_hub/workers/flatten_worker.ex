defmodule KiteAgentHub.Workers.FlattenWorker do
  @moduledoc """
  Closes ALL of an agent's open Alpaca positions when the user's
  configured `flatten_at_dd_pct` threshold has been breached. This is
  the action arm of `KiteAgentHub.Trading.DrawdownGate` — the gate
  blocks the new entry AND enqueues this worker, which then unwinds
  what's already in the market.

  ## Legal framing

  Same as the rest of `DrawdownGate`: KAH does not pick the threshold,
  the user does. This worker executes the user's pre-set rule, never
  one KAH imposed. See `KiteAgentHub.Trading.DrawdownGate` moduledoc
  for the broker-dealer / RIA framing.

  ## Idempotency

  Oban-level `:unique` on the args fingerprint with an 86_400 second
  (24h) window — the same agent's flatten cannot be re-enqueued within
  the same day. Without this guard a tight retry loop or repeated
  trade-attempts-during-breach would spawn N flatten jobs and double-
  sell positions on the second pass.

  ## Runtime safety (CyberSec ask 14209)

  * Re-fetches the agent from DB inside `perform/1` and bails if the
    user removed the threshold between enqueue and execution. Stale
    rules MUST NOT trigger live closes.
  * Pulls Alpaca credentials at runtime via
    `Credentials.fetch_secret_with_env/2`. **No key material in the
    Oban jobs table.**
  * Every close attempt writes an `agent_dd_audit_log` row
    (`action="executed_close"` on success, `"close_failed"` on
    transient/permanent failure) so the user can see exactly what was
    closed and what wasn't.

  Phase 2b covers Alpaca-only flatten (matches Phase 1b's Alpaca-only
  DD calc). OANDA/Kalshi position closes ship in Phase 2d.
  """
  use Oban.Worker,
    queue: :trade_execution,
    max_attempts: 3,
    unique: [period: 86_400, fields: [:args], keys: [:agent_id]]

  require Logger

  alias KiteAgentHub.{Credentials, Repo}
  alias KiteAgentHub.Trading
  alias KiteAgentHub.Trading.{DdAuditLog, KiteAgent}
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"agent_id" => agent_id} = args}) do
    threshold = Map.get(args, "threshold_pct")

    case Repo.get(KiteAgent, agent_id) do
      nil ->
        Logger.warning("FlattenWorker: agent #{agent_id} not found at job time — skipping")
        :ok

      %KiteAgent{flatten_at_dd_pct: nil} ->
        # User cleared the threshold after the job enqueued. Per
        # CyberSec ask 14209 #1, do NOT close on a stale rule.
        Logger.info(
          "FlattenWorker: agent #{agent_id} has cleared flatten_at_dd_pct — skipping close"
        )

        :ok

      %KiteAgent{} = agent ->
        flatten_alpaca(agent, threshold)
    end
  end

  defp flatten_alpaca(%KiteAgent{} = agent, threshold) do
    case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
      {:error, :not_configured} ->
        Logger.info(
          "FlattenWorker: agent #{agent.id} has no Alpaca creds — skipping Alpaca close path"
        )

        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.positions_uncached(key_id, secret, env) do
          {:ok, positions} ->
            Enum.each(positions, &close_position(&1, agent, threshold, key_id, secret, env))
            :ok

          {:error, reason} ->
            Logger.warning(
              "FlattenWorker: agent #{agent.id} positions fetch failed: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp close_position(%{symbol: symbol, qty: qty}, agent, threshold, key_id, secret, env)
       when is_binary(symbol) and is_number(qty) and qty != 0 do
    {close_side, close_qty} =
      cond do
        qty > 0 -> {"sell", qty}
        qty < 0 -> {"buy", abs(qty)}
      end

    case AlpacaClient.place_order(key_id, secret, symbol, close_qty, close_side, env) do
      {:ok, _} ->
        write_audit(
          agent,
          threshold,
          "executed_close",
          "flatten close placed for #{symbol} #{close_side} #{close_qty}"
        )

      {:error, reason} ->
        Logger.warning(
          "FlattenWorker: agent #{agent.id} close failed for #{symbol}: #{inspect(reason)}"
        )

        write_audit(
          agent,
          threshold,
          "close_failed",
          "flatten close failed for #{symbol}: #{inspect(reason)}"
        )
    end
  end

  defp close_position(_position, _agent, _threshold, _key_id, _secret, _env), do: :ok

  defp write_audit(agent, threshold, action, reason) do
    threshold_decimal =
      cond do
        is_number(threshold) -> Decimal.from_float(threshold * 1.0)
        true -> agent.flatten_at_dd_pct
      end

    %DdAuditLog{}
    |> DdAuditLog.changeset(%{
      kite_agent_id: agent.id,
      threshold_type: "flatten",
      threshold_value: threshold_decimal,
      equity: nil,
      dd_pct: nil,
      action: action,
      reason: reason
    })
    |> Repo.insert()
    |> case do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "FlattenWorker: audit log insert failed for agent #{agent.id}: #{inspect(changeset.errors)}"
        )

        :ok
    end
  end

  @doc false
  def trading_alias, do: Trading
end
