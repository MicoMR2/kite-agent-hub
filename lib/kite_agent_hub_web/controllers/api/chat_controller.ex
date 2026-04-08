defmodule KiteAgentHubWeb.API.ChatController do
  @moduledoc """
  REST API for the in-platform agent chat.

  Lets external LLMs (Claude Code, Claude Desktop, any MCP client) read
  and write to the chat thread for their organization using an agent
  `api_token` as the Bearer credential.

  ## Endpoints

    * `POST /api/v1/chat` — send a message as this agent
    * `GET  /api/v1/chat` — list recent messages (supports `after_id`, `before_id`, `limit`)
    * `GET  /api/v1/chat/wait` — long-poll for new messages, blocks up to 60s

  All reads and writes are scoped to the authenticated agent's
  `organization_id` — no cross-workspace access.
  """
  use KiteAgentHubWeb, :controller

  require Logger
  alias KiteAgentHub.{Trading, Chat}

  @wait_timeout_ms 60_000

  # ── POST /api/v1/chat ─────────────────────────────────────────────────────

  def create(conn, %{"text" => text}) when is_binary(text) and text != "" do
    with {:ok, agent} <- authenticate(conn) do
      case Chat.send_agent_message(agent.organization_id, agent, text) do
        {:ok, message} ->
          conn |> put_status(:created) |> json(%{ok: true, message: serialize(message)})

        {:error, _} ->
          conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: "failed to send message"})
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{ok: false, error: "text is required"})
  end

  # ── GET /api/v1/chat ──────────────────────────────────────────────────────

  def index(conn, params) do
    with {:ok, agent} <- authenticate(conn) do
      limit = params |> Map.get("limit", "50") |> parse_int(50) |> min(100)
      after_id = Map.get(params, "after_id")

      messages = Chat.list_messages(agent.organization_id, limit: limit, after_id: after_id)

      conn |> json(%{ok: true, messages: Enum.map(messages, &serialize/1)})
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  # ── GET /api/v1/chat/wait ─────────────────────────────────────────────────
  # Long-poll: blocks up to 60s waiting for a new chat message broadcast
  # to the agent's org. Returns 200 with the new messages array on arrival,
  # or 204 on timeout (client should reconnect immediately, same as BotFreq).

  def wait(conn, params) do
    with {:ok, agent} <- authenticate(conn) do
      org_id = agent.organization_id
      after_id = Map.get(params, "after_id")

      # If there are already newer messages, return them immediately.
      case Chat.list_messages(org_id, limit: 50, after_id: after_id) do
        [_ | _] = messages ->
          conn |> json(%{ok: true, messages: Enum.map(messages, &serialize/1)})

        [] ->
          Chat.subscribe(org_id)
          receive do
            {:chat_message, msg} ->
              Chat.unsubscribe(org_id)
              conn |> json(%{ok: true, messages: [serialize(msg)]})
          after
            @wait_timeout_ms ->
              Chat.unsubscribe(org_id)
              conn |> send_resp(:no_content, "")
          end
      end
    else
      {:error, :unauthorized} -> unauthorized(conn)
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Trading.get_agent_by_token(token) || Trading.get_agent_by_wallet(token) do
          nil -> {:error, :unauthorized}
          agent -> {:ok, agent}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  defp unauthorized(conn),
    do: conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

  defp serialize(msg) do
    %{
      id: msg.id,
      text: msg.text,
      sender_type: msg.sender_type,
      sender_name: msg.sender_name,
      kite_agent_id: msg.kite_agent_id,
      user_id: msg.user_id,
      organization_id: msg.organization_id,
      inserted_at: msg.inserted_at
    }
  end

  defp parse_int(str, default) do
    case Integer.parse(to_string(str)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end
end
