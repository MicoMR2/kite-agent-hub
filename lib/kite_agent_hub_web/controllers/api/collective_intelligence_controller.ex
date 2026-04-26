defmodule KiteAgentHubWeb.API.CollectiveIntelligenceController do
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.CollectiveIntelligence
  alias KiteAgentHub.Trading

  def index(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      conn
      |> json(%{
        ok: true,
        collective_intelligence: CollectiveIntelligence.summary_for_org(agent.organization_id)
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  defp authenticate(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Trading.get_agent_by_token(token) do
          nil -> {:error, :unauthorized}
          agent -> {:ok, agent}
        end

      _ ->
        {:error, :unauthorized}
    end
  end
end
