defmodule KiteAgentHubWeb.API.ForexPortfolioController do
  @moduledoc """
  REST endpoint for external trading agents to read their OANDA
  practice portfolio — balance, NAV, unrealized P&L, and open
  positions. Mirror of `/api/v1/portfolio` (Alpaca) so agents can
  reason about forex exposure the same way they reason about equities.

  ## Endpoint

      GET /api/v1/forex/portfolio

  ## Response

      {
        "ok": true,
        "provider": "oanda_practice",
        "account": {
          "balance": "100000.0000",
          "nav": "100000.0000",
          "unrealized_pl": "0.0000",
          "margin_used": "0.0000",
          "currency": "USD"
        },
        "positions": [
          {
            "instrument": "EUR_USD",
            "units": "1000",
            "side": "long",
            "unrealized_pl": "1.23"
          }
        ]
      }

  Auth: Bearer agent api_token (same as other /api/v1 endpoints).
  OANDA credentials are pulled encrypted per-org — the response body
  never contains the token or the raw account_id.
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.{Oanda, Trading}
  alias KiteAgentHub.Api.RateLimiter

  def show(conn, _params) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- RateLimiter.check(agent.id),
         org_id when is_binary(org_id) <- agent.organization_id do
      if Oanda.configured?(org_id, :practice) do
        account = Oanda.account_summary(org_id, :practice) || %{}
        positions = Oanda.list_positions(org_id, :practice)

        conn
        |> json(%{
          ok: true,
          provider: "oanda_practice",
          account: serialize_account(account),
          positions: Enum.map(positions, &serialize_position/1)
        })
      else
        conn
        |> put_status(:ok)
        |> json(%{
          ok: true,
          provider: "oanda_practice",
          account: nil,
          positions: [],
          error: "oanda_practice credentials not configured for this org"
        })
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{ok: false, error: "rate limited"})

      nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "agent has no organization"})

      other ->
        Logger.warning("ForexPortfolioController: upstream fetch failed: #{inspect(other)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "portfolio fetch failed"})
    end
  end

  # Only surface OANDA-sourced public fields. account_id and the API
  # token are intentionally excluded — the agent knows its own org
  # already, and the token is a write-only secret on KAH's side.
  defp serialize_account(%{} = account) do
    %{
      balance: Oanda.field(account, "balance", nil),
      nav: Oanda.field(account, "NAV", nil),
      unrealized_pl: Oanda.field(account, "unrealizedPL", nil),
      margin_used: Oanda.field(account, "marginUsed", nil),
      currency: Oanda.field(account, "currency", nil)
    }
  end

  defp serialize_account(_), do: %{}

  # OANDA represents a position as {long: {units, pl}, short: {units, pl}}.
  # Pick whichever side has non-zero units and report a single side.
  defp serialize_position(%{} = pos) do
    {side, details} =
      cond do
        has_units?(Map.get(pos, "long")) -> {"long", Map.get(pos, "long", %{})}
        has_units?(Map.get(pos, "short")) -> {"short", Map.get(pos, "short", %{})}
        true -> {"flat", %{}}
      end

    %{
      instrument: Oanda.field(pos, "instrument", nil),
      units: Oanda.field(details, "units", "0"),
      side: side,
      unrealized_pl: Oanda.field(details, "unrealizedPL", "0")
    }
  end

  defp serialize_position(_), do: %{}

  defp has_units?(%{"units" => u}) when is_binary(u), do: u != "0" and u != ""
  defp has_units?(_), do: false

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
