defmodule KiteAgentHubWeb.API.BrokerOrdersController do
  @moduledoc """
  Read-through endpoint for live broker-side open orders, so agents can
  catch ghost orders BEFORE they queue a same-symbol entry and trip a
  wash-trade block. Phorari PR #4 scope (msg 6274).

  Where `/api/v1/trades` shows the hub's DB view and `/api/v1/portfolio`
  shows positions, this surfaces what Alpaca still has open on the
  broker book — which is where the SLB/HAL zombie-sell bug hid between
  Apr 8-10. DB said settled, Alpaca said open, and agents couldn't tell.

  ## Endpoint

    GET /api/v1/broker/orders[?status=open&limit=50]

  `status` defaults to `"open"`. Also accepted: `"closed"`, `"all"`, or
  any status string Alpaca's /v2/orders endpoint supports. `limit` is
  1..500 (default 50).

  ## Response

    {
      "ok": true,
      "status": "open",
      "orders": [
        {
          "id": "f526b7f9-...",
          "symbol": "SLB",
          "side": "sell",
          "qty": 10.0,
          "filled_qty": 0.0,
          "filled_avg_price": null,
          "status": "new",
          "submitted_at": "2026-04-08T14:22:10Z"
        }
      ]
    }

  Auth: Bearer agent api_token. Alpaca credentials sourced per-org via
  `Credentials.fetch_secret_with_env/2` — agent never holds raw keys.

  Kalshi reconciliation is intentionally out of scope for this PR;
  Alpaca covers the equities side where the wash-block problem is
  happening. Kalshi orders can be layered on when the Kalshi client
  grows a list_orders equivalent.
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  # Intentionally permissive — pass through whatever status the agent
  # asks for and let Alpaca 4xx bad values rather than encode the full
  # enum here. Keeps the endpoint forward-compatible when Alpaca adds
  # new status strings.
  @default_status "open"
  @default_limit 50
  @max_limit 500

  def index(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, status} <- fetch_status(params),
         {:ok, limit} <- fetch_limit(params),
         {:ok, {key_id, secret, env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca),
         {:ok, orders} <- AlpacaClient.list_orders(key_id, secret, status, limit, env) do
      conn
      |> json(%{ok: true, status: status, orders: Enum.map(orders, &serialize/1)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :bad_status} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "status must be a non-empty alphanumeric string"})

      {:error, :bad_limit} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "limit must be an integer between 1 and #{@max_limit}"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured for this org"})

      {:error, reason} ->
        Logger.warning("BrokerOrdersController: upstream fetch failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "broker orders fetch failed: #{inspect(reason)}"})
    end
  end

  def cancel(conn, %{"order_id" => order_id}) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- require_trading_agent(agent),
         {:ok, _} <- validate_uuid(order_id),
         {:ok, {key_id, secret, env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca),
         {:ok, _} <- AlpacaClient.cancel_order(key_id, secret, order_id, env) do
      Logger.info(
        "BrokerOrdersController: agent #{agent.id} cancelled Alpaca order #{order_id} (env=#{env})"
      )

      json(conn, %{ok: true})
    else
      {:error, :not_trading_agent} ->
        conn
        |> put_status(:forbidden)
        |> json(%{ok: false, error: "only trading agents can cancel orders"})

      {:error, :bad_uuid} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "invalid order_id format"})

      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured"})

      {:error, reason} ->
        Logger.warning("BrokerOrdersController: cancel failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "cancel failed: #{inspect(reason)}"})
    end
  end

  defp require_trading_agent(%{agent_type: "trading"}), do: :ok
  defp require_trading_agent(_), do: {:error, :not_trading_agent}

  defp validate_uuid(id) when is_binary(id) do
    if Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, id),
      do: {:ok, id},
      else: {:error, :bad_uuid}
  end

  defp validate_uuid(_), do: {:error, :bad_uuid}

  defp serialize(order) do
    %{
      id: order.id,
      symbol: order.symbol,
      side: order.side,
      qty: order.qty,
      filled_qty: order.filled_qty,
      filled_avg_price: order.filled_avg_price,
      status: order.status,
      submitted_at: order.submitted_at
    }
  end

  # Defend the URL injection vector before anything hits Alpaca. Status
  # strings are short alphanumeric tokens — reject anything that isn't.
  defp fetch_status(params) do
    raw = Map.get(params, "status", @default_status) |> to_string() |> String.trim()

    cond do
      raw == "" -> {:error, :bad_status}
      Regex.match?(~r/\A[a-z_]{1,24}\z/, raw) -> {:ok, raw}
      true -> {:error, :bad_status}
    end
  end

  defp fetch_limit(params) do
    case Map.get(params, "limit", @default_limit) do
      n when is_integer(n) and n >= 1 and n <= @max_limit ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 1 and n <= @max_limit -> {:ok, n}
          _ -> {:error, :bad_limit}
        end

      _ ->
        {:error, :bad_limit}
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
