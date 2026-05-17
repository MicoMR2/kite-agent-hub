defmodule KiteAgentHubWeb.Plugs.AuthenticateAgent do
  @moduledoc """
  Authenticates an agent via `Authorization: Bearer <api_token>` and
  populates `conn.assigns.current_agent` + `conn.assigns.current_org_id`
  for downstream controllers.

  Unifies what was previously a per-controller `defp authenticate/1`
  copy across all 13 `/api/v1/*` controllers. Centralizing the lookup
  removes the "default insecure" risk that a future controller is
  added without remembering to call the auth helper — the router-level
  plug ensures every request through the `:api` pipeline either has a
  resolved agent in assigns or has already been halted with 401.

  Failure shape (intentional, matches the prior per-controller shape):
    * No / malformed Authorization header → 401 `{ok: false, error: "invalid api key"}`
    * Token does not resolve to an agent  → 401 `{ok: false, error: "invalid api key"}`
    * DB rescue / unexpected exception     → 503 `{ok: false, error: "service unavailable"}`
      (preserves the soft-timeout behavior ChatController used to provide
      when the DB blip would otherwise leak a stacktrace through the
      Plug error handler)
  """

  import Plug.Conn

  require Logger

  alias KiteAgentHub.Trading

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 ->
        lookup_and_assign(conn, token)

      _ ->
        halt_unauthorized(conn)
    end
  end

  defp lookup_and_assign(conn, token) do
    case Trading.get_agent_by_token(token) do
      nil ->
        halt_unauthorized(conn)

      agent ->
        conn
        |> assign(:current_agent, agent)
        |> assign(:current_org_id, agent.organization_id)
    end
  rescue
    e ->
      Logger.warning(
        "AuthenticateAgent: agent lookup rescued #{Exception.message(e)} — returning soft 503"
      )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(503, ~s({"ok":false,"error":"service unavailable"}))
      |> halt()
  end

  defp halt_unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, ~s({"ok":false,"error":"invalid api key"}))
    |> halt()
  end
end
