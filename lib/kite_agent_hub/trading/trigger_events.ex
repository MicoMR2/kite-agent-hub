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

  alias Ecto.Multi
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TriggerEvent

  @pubsub_topic_prefix "trigger_events:"

  @doc """
  Phoenix.PubSub topic an agent runner subscribes to in order to wake
  its long-poll on a new emit. One topic per agent.
  """
  @spec pubsub_topic(binary()) :: String.t()
  def pubsub_topic(agent_id) when is_binary(agent_id),
    do: @pubsub_topic_prefix <> agent_id

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
      {:ok, event} = ok ->
        broadcast_new(event)
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
  Atomically claim every currently-pending event for an agent: SELECT
  the rows, UPDATE WHERE status='pending' AND delivered_at IS NULL to
  'delivered' inside a single transaction. The clause makes the update
  idempotent under concurrent polls — a second caller will see zero
  rows to claim (CyberSec ask 4, msg 9123).

  Returns the list of events that this call transitioned. Events that
  were already delivered are not included.
  """
  @spec claim_pending_for_agent(binary()) :: [TriggerEvent.t()]
  def claim_pending_for_agent(agent_id) when is_binary(agent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Multi.new()
    |> Multi.run(:select, fn repo, _ ->
      rows =
        from(t in TriggerEvent,
          where:
            t.agent_id == ^agent_id and t.status == "pending" and is_nil(t.delivered_at),
          order_by: [asc: t.inserted_at],
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> repo.all()

      {:ok, rows}
    end)
    |> Multi.run(:update, fn repo, %{select: rows} ->
      ids = Enum.map(rows, & &1.id)

      {count, _} =
        from(t in TriggerEvent, where: t.id in ^ids)
        |> repo.update_all(set: [status: "delivered", delivered_at: now])

      {:ok, count}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{select: rows}} ->
        Enum.map(rows, fn r -> %{r | status: "delivered", delivered_at: now} end)

      {:error, _, _, _} ->
        []
    end
  end

  @doc """
  Look up a single event scoped to the calling agent. Returns
  `:not_found` for non-existent rows AND for cross-agent attempts —
  the controller cannot distinguish, so an enumeration probe can't
  use the response to confirm an event id exists on another agent
  (CyberSec ask 5, msg 9123).
  """
  @spec get_for_agent(binary(), binary()) :: {:ok, TriggerEvent.t()} | :not_found
  def get_for_agent(event_id, agent_id)
      when is_binary(event_id) and is_binary(agent_id) do
    case Repo.get(TriggerEvent, event_id) do
      %TriggerEvent{agent_id: ^agent_id} = ev -> {:ok, ev}
      _ -> :not_found
    end
  end

  defp broadcast_new(%TriggerEvent{agent_id: agent_id} = event) do
    Phoenix.PubSub.broadcast(
      KiteAgentHub.PubSub,
      pubsub_topic(agent_id),
      {:trigger_event_emitted, event.id}
    )

    :ok
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
