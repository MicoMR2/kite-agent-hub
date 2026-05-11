defmodule KiteAgentHubWeb.API.TriggersController do
  @moduledoc """
  Trigger-event dispatch endpoint for Passport-routed agents.

  GET /api/v1/triggers/pending — long-poll. Returns up to N pending
  trigger events for the authenticated agent. Atomically marks them
  delivered in the same call. Long-poll uses `Phoenix.PubSub` to wake
  on a new emit; no DB connection is held while waiting.

  POST /api/v1/triggers/:id/ack — client confirmation hook. No-op
  today (claim already happens on GET) but exposed so a kpass-side
  runner can signal successful local execution. Cross-agent ack
  attempts return 404, never 403 (CyberSec ask 5, msg 9123).

  Auth is via the agent's Bearer api_token, same pattern as
  `TradesController` — no new auth surface (CyberSec ask 1, msg 9123,
  Phorari Gate 2 msg 9124).
  """

  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Api.RateLimiter
  alias KiteAgentHub.Trading
  alias KiteAgentHub.Trading.TriggerEvents

  # Server-side cap on long-poll wait. Not client-overridable
  # (CyberSec ask 6, msg 9123). The 10s default is shortened in the
  # test environment via :triggers_long_poll_ms so the suite doesn't
  # block for the full prod cap on the empty-queue path.
  defp long_poll_ms,
    do: Application.get_env(:kite_agent_hub, :triggers_long_poll_ms, 10_000)

  def index(conn, _params) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- RateLimiter.check(agent.id) do
      events = TriggerEvents.claim_pending_for_agent(agent.id)

      events =
        case events do
          [] -> wait_for_new(agent.id)
          _ -> events
        end

      json(conn, %{ok: true, events: Enum.map(events, &serialize_event/1)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{ok: false, error: "rate_limited"})
    end
  end

  def ack(conn, %{"id" => event_id}) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, _event} <- TriggerEvents.get_for_agent(event_id, agent.id) do
      send_resp(conn, :no_content, "")
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "unauthorized"})

      :not_found ->
        conn |> put_status(:not_found) |> json(%{ok: false, error: "not_found"})
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  # Bearer-only Authorization header. Header is parsed BEFORE any DB
  # lookup (CyberSec ask 1, msg 9123) — a malformed header short-
  # circuits the request without burning a connection. Token lookup
  # itself is an indexed equality match in Postgres (parity with
  # TradesController.authenticate/1).
  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when token != "" ->
        case Trading.get_agent_by_token(token) do
          nil -> {:error, :unauthorized}
          agent -> {:ok, agent}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # Subscribe to the per-agent PubSub topic and wait up to
  # @long_poll_ms for an emit to land. Returns claimed events on
  # wake, or [] on timeout. No DB connection is held during the
  # `receive` (CyberSec ask 6, msg 9123).
  defp wait_for_new(agent_id) do
    topic = TriggerEvents.pubsub_topic(agent_id)
    Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, topic)

    try do
      receive do
        {:trigger_event_emitted, _id} -> TriggerEvents.claim_pending_for_agent(agent_id)
      after
        long_poll_ms() -> []
      end
    after
      Phoenix.PubSub.unsubscribe(KiteAgentHub.PubSub, topic)
    end
  end

  # Explicit field-by-field allowlist (CyberSec ask 3, msg 9123). The
  # full TriggerEvent struct is never serialized — that would leak the
  # payload jsonb wholesale and could expose any future internal field.
  defp serialize_event(event) do
    payload = event.payload || %{}

    %{
      id: event.id,
      event_type: event.event_type,
      symbol: Map.get(payload, "symbol") || Map.get(payload, :symbol),
      side: Map.get(payload, "side") || Map.get(payload, :side),
      qty: Map.get(payload, "qty") || Map.get(payload, :qty),
      idempotency_key: event.idempotency_key,
      created_at: event.inserted_at
    }
  end
end
