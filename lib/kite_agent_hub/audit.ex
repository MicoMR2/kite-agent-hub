defmodule KiteAgentHub.Audit do
  @moduledoc """
  Context for the append-only audit_logs table.

  Currently writes one event class: live-slot credential mutations
  (CyberSec ask 8 on PR #364, finalized at msg 9199). The write
  surface is intentionally narrow — every new audit-loggable
  operation gets its own helper on this module so the call sites
  do not assemble raw attrs.

  Soft-failure: a failed audit insert logs an error and emits a
  telemetry event but does NOT raise or roll back the caller's
  operation. Audit is observability, not enforcement — blocking the
  credential write because the audit row could not be persisted
  would be worse than the missing row (Phorari directive, msg 9198).
  """

  require Logger

  alias KiteAgentHub.Audit.AuditLog
  alias KiteAgentHub.Repo

  @doc """
  Audit a chain_id flip on a trading agent. Only writes a row on an
  actual transition (`from != to`) per CyberSec ask 6 at msg 9212 —
  no-op saves stay out of the audit table.

  `metadata` is `%{from: integer, to: integer}` — both ints, safe to
  store. The sanitizer would strip any accidental secret-shaped key
  but there is nothing sensitive here.
  """
  @spec log_chain_change(
          String.t() | integer(),
          String.t(),
          String.t(),
          integer(),
          integer()
        ) :: :ok
  def log_chain_change(actor_user_id, org_id, agent_id, from_chain, to_chain)
      when is_binary(agent_id) and is_integer(from_chain) and is_integer(to_chain) do
    if from_chain == to_chain do
      :ok
    else
      log_event(
        actor_user_id,
        org_id,
        :agent_chain_changed,
        "kite_agent",
        agent_id,
        %{"from" => from_chain, "to" => to_chain}
      )
    end
  end

  defp log_event(actor_user_id, org_id, action, target_type, target_id, metadata) do
    action_str = to_string(action)

    attrs = %{
      actor_user_id: to_string(actor_user_id),
      org_id: to_string(org_id),
      action: action_str,
      target_type: target_type,
      target_id: target_id,
      metadata: metadata
    }

    try do
      case attrs |> AuditLog.insert_changeset() |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, cs} ->
          Logger.error(
            "Audit.log_event REJECTED action=#{action_str} target_type=#{target_type} actor_user_id=#{attrs.actor_user_id} errors=#{inspect(cs.errors)}"
          )

          :telemetry.execute([:kah, :audit, :write_failed], %{count: 1}, %{action: action_str})
          :ok
      end
    rescue
      e ->
        Logger.error(
          "Audit.log_event CRASH action=#{action_str} target_type=#{target_type} actor_user_id=#{attrs.actor_user_id} reason=#{Exception.message(e)}"
        )

        :telemetry.execute([:kah, :audit, :write_failed], %{count: 1}, %{action: action_str})
        :ok
    end
  end

  @spec log_live_credential_event(
          String.t() | binary(),
          String.t() | binary(),
          atom() | String.t(),
          String.t(),
          map()
        ) :: :ok
  def log_live_credential_event(actor_user_id, org_id, action, target_slug, metadata \\ %{})
      when is_binary(target_slug) do
    action_str = to_string(action)

    attrs = %{
      actor_user_id: to_string(actor_user_id),
      org_id: to_string(org_id),
      action: action_str,
      target_type: "api_credential",
      target_id: target_slug,
      metadata: metadata
    }

    try do
      case attrs |> AuditLog.insert_changeset() |> Repo.insert() do
        {:ok, _} ->
          :ok

        {:error, cs} ->
          # CyberSec ask (c) msg 9199: error log includes action +
          # target_type + actor_user_id only — never the metadata
          # blob (which may carry recovered keys we did not strip).
          Logger.error(
            "Audit.log_live_credential_event REJECTED action=#{action_str} target_type=api_credential actor_user_id=#{attrs.actor_user_id} errors=#{inspect(cs.errors)}"
          )

          :telemetry.execute(
            [:kah, :audit, :write_failed],
            %{count: 1},
            %{action: action_str}
          )

          :ok
      end
    rescue
      e ->
        Logger.error(
          "Audit.log_live_credential_event CRASH action=#{action_str} target_type=api_credential actor_user_id=#{attrs.actor_user_id} reason=#{Exception.message(e)}"
        )

        :telemetry.execute(
          [:kah, :audit, :write_failed],
          %{count: 1},
          %{action: action_str}
        )

        :ok
    end
  end
end
