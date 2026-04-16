defmodule KiteAgentHubWeb.API.AgentsController do
  @moduledoc """
  Agent management — edit profile fields, rotate the API token, and
  archive (soft-delete). Backs the Settings > Agents UI (Phorari PR
  msg 6341) plus programmatic control from the authenticated agent
  itself.

  ## Auth model

  Bearer `agent_api_token`. The caller can only act on themselves —
  agent_id in the URL must match the authenticated agent's id. No
  cross-org, no cross-agent mutations. CyberSec guardrail from msg
  6339: "must verify the agent belongs to the authenticated user's
  org before edit/delete". We enforce that via the token check since
  each token uniquely identifies one agent.

  ## Endpoints

    PATCH  /api/v1/agents/:id              — edit profile
    POST   /api/v1/agents/:id/rotate_token — rotate api_token
    DELETE /api/v1/agents/:id              — archive (soft-delete)

  ## PATCH body

    {"name": "...", "tags": ["..."], "bio": "..."}

  Whitelist is enforced in `KiteAgent.profile_changeset/2` —
  api_token, wallet_address, status, organization_id are explicitly
  NOT accepted from the request body (CyberSec msg 6339).

  ## Rotate response

    {"ok": true, "agent": {..., "api_token": "kite_..."}}

  The plaintext token is returned ONCE. Persist it on the caller side
  — subsequent reads will not include it.

  ## DELETE response

    {"ok": true, "agent": {...}, "cancelled_open_trades": N}

  Archive stops the agent's runner and auto-cancels every still-open
  trade it holds via the same path StuckTradeSweeper uses, so the
  broker book clears too.
  """
  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.Trading

  def update(conn, %{"id" => id} = params) do
    with {:ok, agent} <- authenticate_as(conn, id),
         {:ok, updated} <- Trading.update_agent_profile(agent, profile_attrs(params)) do
      conn |> json(%{ok: true, agent: serialize(updated, include_token: false)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{ok: false, error: "agent mismatch"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, errors: translate_errors(changeset)})
    end
  end

  def rotate_token(conn, %{"id" => id}) do
    with {:ok, agent} <- authenticate_as(conn, id),
         {:ok, updated} <- Trading.rotate_agent_api_token(agent) do
      conn |> json(%{ok: true, agent: serialize(updated, include_token: true)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{ok: false, error: "agent mismatch"})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: "rotation failed"})
    end
  end

  def archive(conn, %{"id" => id}) do
    with {:ok, agent} <- authenticate_as(conn, id),
         {:ok, %{agent: archived, cancelled_count: count}} <- Trading.archive_agent(agent) do
      conn
      |> json(%{
        ok: true,
        agent: serialize(archived, include_token: false),
        cancelled_open_trades: count
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :forbidden} ->
        conn |> put_status(:forbidden) |> json(%{ok: false, error: "agent mismatch"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, errors: translate_errors(changeset)})
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  # Auth AND ownership in one pass: the bearer token identifies exactly
  # one agent; the URL id must match. Anything else → :forbidden so we
  # don't leak whether a given id exists across orgs.
  defp authenticate_as(conn, url_id) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case Trading.get_agent_by_token(token) do
          nil ->
            {:error, :unauthorized}

          agent ->
            if agent.id == url_id do
              {:ok, agent}
            else
              {:error, :forbidden}
            end
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  # Accept only the whitelist; drop anything else silently so clients
  # that send api_token / wallet_address / status by mistake don't
  # escalate. The schema's profile_changeset re-enforces this with
  # `cast(attrs, [:name, :tags, :bio])`, but filtering here keeps
  # input audit trails clean.
  defp profile_attrs(params) do
    Map.take(params, ["name", "tags", "bio"])
  end

  defp serialize(agent, opts) do
    base = %{
      id: agent.id,
      name: agent.name,
      agent_type: agent.agent_type,
      status: agent.status,
      wallet_address: agent.wallet_address,
      vault_address: agent.vault_address,
      organization_id: agent.organization_id,
      tags: agent.tags,
      bio: agent.bio,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }

    if Keyword.get(opts, :include_token, false) do
      Map.put(base, :api_token, agent.api_token)
    else
      base
    end
  end

  defp translate_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
