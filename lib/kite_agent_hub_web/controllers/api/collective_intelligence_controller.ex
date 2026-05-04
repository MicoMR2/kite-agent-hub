defmodule KiteAgentHubWeb.API.CollectiveIntelligenceController do
  @moduledoc """
  Reciprocity gate: only orgs that have opted in can read shared
  insights. By contributing your settled-trade outcomes (anonymized,
  bucketed) you also gain access to everyone elses contributions.
  Opted-out orgs get 403 here so the boundary is explicit instead
  of returning a silently-empty body.
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.CollectiveIntelligence
  alias KiteAgentHub.Trading

  def index(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      org_id = agent.organization_id

      if CollectiveIntelligence.enabled_for_org?(org_id) do
        conn
        |> json(%{
          ok: true,
          collective_intelligence: CollectiveIntelligence.summary_for_org(org_id)
        })
      else
        conn
        |> put_status(:forbidden)
        |> json(%{
          ok: false,
          error: "kci_not_enabled",
          message:
            "Kite Collective Intelligence is opt-in. Enable it in Settings — Collective Intelligence to contribute settled-trade outcomes (anonymized, bucketed) and gain access to shared insights.",
          consent_version: CollectiveIntelligence.consent_version()
        })
      end
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
