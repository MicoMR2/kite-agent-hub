defmodule KiteAgentHubWeb.API.ChatController do
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.{Trading, Chat}

  def create(conn, %{"text" => text}) when is_binary(text) and text != "" do
    with {:ok, agent} <- authenticate(conn) do
      case Chat.send_agent_message(agent.organization_id, agent, text) do
        {:ok, message} ->
          conn |> put_status(:created) |> json(%{ok: true, message_id: message.id})

        {:error, _} ->
          conn |> put_status(:unprocessable_entity) |> json(%{ok: false, error: "failed to send message"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  def create(conn, _params) do
    conn |> put_status(:bad_request) |> json(%{ok: false, error: "text is required"})
  end

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
end
