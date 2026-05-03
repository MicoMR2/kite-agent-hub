defmodule KiteAgentHubWeb.API.ForexPortfolioController do
  @moduledoc """
  REST endpoint for external trading agents to read their OANDA
  practice portfolio — balance, NAV, unrealized P&L, and open
  positions. Mirror of `/api/v1/portfolio` (Alpaca) so agents can
  reason about forex exposure the same way they reason about equities.

  ## Endpoint

      GET /api/v1/forex/portfolio
      GET /api/v1/forex/portfolio?env=practice&instruments=EUR_USD,GBP_USD

  ## Response

      {
        "ok": true,
        "provider": "oanda_practice",
        "env": "practice",
        "can_submit_trades": true,
        "trade_provider": "oanda_practice",
        "order_note": "Submit forex via POST /api/v1/trades with provider \\"oanda_practice\\". oanda_live is rejected.",
        "account": { ... },
        "positions": [ ... ],
        "instruments": [{"name": "EUR_USD", "type": "CURRENCY", ...}],
        "pricing": [{"instrument": "EUR_USD", "bids": [...], "asks": [...]}]
      }

  Query params:
    * `env` — `practice` (default) or `live`. Live forex is read-only.
    * `instruments` — comma-separated OANDA pairs. When supplied, the
      response includes a `pricing` array of live bid/ask quotes.

  Trading is only enabled when `trade_provider` is non-null AND
  `can_submit_trades` is `true`. As of today only `oanda_practice` is
  ever returned as `trade_provider` — `oanda_live` is rejected at the
  trades endpoint, so agents reading this should treat live as a
  view-only data source.

  Auth: Bearer agent api_token (same as other /api/v1 endpoints).
  OANDA credentials are pulled encrypted per-org — the response body
  never contains the token or the raw account_id.
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.{Oanda, Trading}
  alias KiteAgentHub.Api.RateLimiter

  def show(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- RateLimiter.check(agent.id),
         org_id when is_binary(org_id) <- agent.organization_id do
      env = parse_env(params["env"])
      requested_instruments = parse_instruments(params["instruments"])
      provider_label = provider_label(env)
      practice_configured? = Oanda.configured?(org_id, :practice)
      env_configured? = Oanda.configured?(org_id, env)

      if env_configured? do
        account = Oanda.account_summary(org_id, env) || %{}
        positions = Oanda.list_positions(org_id, env)
        instruments = Oanda.list_instruments(org_id, env)

        pricing =
          if requested_instruments == [],
            do: [],
            else: Oanda.pricing(org_id, requested_instruments, env)

        conn
        |> json(%{
          ok: true,
          provider: provider_label,
          env: Atom.to_string(env),
          can_submit_trades: practice_configured?,
          trade_provider: if(practice_configured?, do: "oanda_practice", else: nil),
          order_note: order_note(),
          account: serialize_account(account),
          positions: Enum.map(positions, &serialize_position/1),
          instruments: Enum.map(instruments, &serialize_instrument/1),
          pricing: Enum.map(pricing, &serialize_price/1)
        })
      else
        conn
        |> put_status(:ok)
        |> json(%{
          ok: true,
          provider: provider_label,
          env: Atom.to_string(env),
          can_submit_trades: practice_configured?,
          trade_provider: if(practice_configured?, do: "oanda_practice", else: nil),
          order_note: order_note(),
          account: nil,
          positions: [],
          instruments: [],
          pricing: [],
          error: "#{provider_label} credentials not configured for this org"
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

  defp parse_env("live"), do: :live
  defp parse_env(_), do: :practice

  defp provider_label(:live), do: "oanda_live"
  defp provider_label(_), do: "oanda_practice"

  defp parse_instruments(nil), do: []
  defp parse_instruments(""), do: []

  defp parse_instruments(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(20)
  end

  defp parse_instruments(value) when is_list(value), do: Enum.take(value, 20)
  defp parse_instruments(_), do: []

  defp order_note,
    do:
      "Submit forex via POST /api/v1/trades with provider \"oanda_practice\". oanda_live is rejected."

  defp serialize_instrument(%{} = inst) do
    %{
      name: Oanda.field(inst, "name", nil),
      type: Oanda.field(inst, "type", nil),
      display_name: Oanda.field(inst, "displayName", nil),
      pip_location: Map.get(inst, "pipLocation"),
      display_precision: Map.get(inst, "displayPrecision"),
      margin_rate: Oanda.field(inst, "marginRate", nil),
      minimum_trade_size: Oanda.field(inst, "minimumTradeSize", nil)
    }
  end

  defp serialize_instrument(_), do: %{}

  # OANDA pricing rows have shape:
  #   %{"instrument" => "EUR_USD",
  #     "bids" => [%{"price" => "1.0921"}],
  #     "asks" => [%{"price" => "1.0923"}],
  #     "closeoutBid" => "1.0921", "closeoutAsk" => "1.0923",
  #     "tradeable" => true, "time" => "..."}
  defp serialize_price(%{} = row) do
    %{
      instrument: Oanda.field(row, "instrument", nil),
      bid: best_price(row, "bids", "closeoutBid"),
      ask: best_price(row, "asks", "closeoutAsk"),
      tradeable: Map.get(row, "tradeable"),
      time: Oanda.field(row, "time", nil)
    }
  end

  defp serialize_price(_), do: %{}

  defp best_price(row, list_key, fallback_key) do
    case Map.get(row, list_key) do
      [%{"price" => p} | _] when is_binary(p) -> p
      _ -> Oanda.field(row, fallback_key, nil)
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
