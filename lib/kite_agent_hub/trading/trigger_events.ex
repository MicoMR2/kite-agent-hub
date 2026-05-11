defmodule KiteAgentHub.Trading.TriggerEvents do
  @moduledoc """
  Context for `trigger_events` — the outbox AgentRunner writes to when
  an agent has opted into Rail B (Passport per-trade fees).

  `emit/3` is the only write path AgentRunner uses; it derives a
  deterministic `idempotency_key` from `(agent_id, event_type, sha256
  of the normalized payload)` so re-emits collapse to a single row at
  the unique index level. `pending_for_agent/1` is the read path PR-6
  will expose over HTTP. `mark_delivered/1` flips a row to delivered
  once a kpass-side runner has acknowledged it.

  Credentials NEVER live on a `TriggerEvent`. The changeset enforces
  this — see `TriggerEvent.changeset/2`.
  """

  import Ecto.Query, warn: false

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TriggerEvent

  @doc """
  Insert a new trigger event. Returns `{:ok, event}`, `{:error,
  :duplicate}` if the idempotency_key collides with an existing row,
  or `{:error, changeset}` on a validation error.

  `payload` is a plain map — typically the trade-intent dict
  AgentRunner would otherwise pass to `TradeExecutionWorker.new`.
  Credential-shaped keys are rejected by the changeset.
  """
  @spec emit(map() | struct(), String.t(), map()) ::
          {:ok, TriggerEvent.t()}
          | {:error, :duplicate}
          | {:error, Ecto.Changeset.t()}
  def emit(%{id: agent_id}, event_type, payload)
      when is_binary(event_type) and is_map(payload) do
    attrs = %{
      agent_id: agent_id,
      event_type: event_type,
      payload: payload,
      idempotency_key: idempotency_key(agent_id, event_type, payload)
    }

    case %TriggerEvent{} |> TriggerEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _} = ok ->
        ok

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :idempotency_key) do
          {:error, :duplicate}
        else
          {:error, cs}
        end
    end
  end

  @doc """
  Return undelivered events for an agent in insertion order. Used by
  the PR-6 poll endpoint and by ops dashboards. RLS-scoped through the
  caller's `Repo.with_user/2` context (callers are responsible).
  """
  @spec pending_for_agent(binary()) :: [TriggerEvent.t()]
  def pending_for_agent(agent_id) when is_binary(agent_id) do
    TriggerEvent
    |> where([t], t.agent_id == ^agent_id and t.status == "pending")
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Mark a previously-pending event as delivered. Idempotent — a row
  that's already delivered is returned unchanged.
  """
  @spec mark_delivered(TriggerEvent.t()) ::
          {:ok, TriggerEvent.t()} | {:error, Ecto.Changeset.t()}
  def mark_delivered(%TriggerEvent{status: "delivered"} = ev), do: {:ok, ev}

  def mark_delivered(%TriggerEvent{} = ev) do
    ev
    |> TriggerEvent.changeset(%{
      status: "delivered",
      delivered_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.update()
  end

  ## Internals

  # Deterministic key over (agent_id, event_type, sha256(normalized
  # payload)). Normalize by encoding with sorted keys so field
  # ordering in the input map doesn't yield different hashes for the
  # same intent. Phorari called this out (msg 9063).
  defp idempotency_key(agent_id, event_type, payload) do
    digest =
      payload
      |> sort_payload()
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{agent_id}:#{event_type}:#{digest}"
  end

  # Walk the value tree and re-emit each map level as a sorted list of
  # [k, v] pairs. Jason encodes the result as nested arrays, which is
  # order-deterministic regardless of how the input map happened to
  # iterate.
  defp sort_payload(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> [to_string(k), sort_payload(v)] end)
    |> Enum.sort_by(fn [k, _] -> k end)
  end

  defp sort_payload(value) when is_list(value), do: Enum.map(value, &sort_payload/1)
  defp sort_payload(value), do: value
end
