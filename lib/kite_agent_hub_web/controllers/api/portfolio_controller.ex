defmodule KiteAgentHubWeb.API.PortfolioController do
  @moduledoc """
  REST endpoint for external agents to read their portfolio state in a
  single call: cash, buying power, equity, plus per-ticker cost basis
  and size as a % of book.

  Where `/api/v1/trades` gives the agent its DB-side trade history and
  `/api/v1/edge-scores` ranks the current position set, this endpoint
  answers "what do I actually hold, and how much room do I have to
  size new entries?" — which Research was previously inferring from
  fill_price math (Phorari PR #3 scope, msg 6274).

  ## Endpoint

    GET /api/v1/portfolio

  ## Response

    {
      "ok": true,
      "account": {
        "cash": 1234.56,
        "buying_power": 2345.67,
        "portfolio_value": 5678.90,
        "equity": 5678.90,
        "day_trade_count": 0,
        "status": "ACTIVE"
      },
      "positions": [
        {
          "symbol": "AAPL",
          "qty": 10.0,
          "side": "long",
          "avg_entry_price": 180.50,
          "current_price": 190.00,
          "market_value": 1900.00,
          "cost_basis": 1805.00,
          "unrealized_pl": 95.00,
          "unrealized_plpc": 0.0526,
          "pct_of_book": 33.45
        }
      ],
      "total_market_value": 5678.90
    }

  Auth: Bearer agent api_token (same as other /api/v1 endpoints).
  Alpaca credentials are pulled encrypted per-org — agent never holds
  raw keys.
  """
  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.{Credentials, Trading}
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  def show(conn, _params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, {key_id, secret, env}} <-
           Credentials.fetch_secret_with_env(agent.organization_id, :alpaca),
         {:ok, account} <- AlpacaClient.account(key_id, secret, env),
         {:ok, positions} <- AlpacaClient.positions(key_id, secret, env) do
      {serialized_positions, total_market_value} = build_positions(positions)

      conn
      |> json(%{
        ok: true,
        account: serialize_account(account),
        positions: serialized_positions,
        total_market_value: total_market_value
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, :not_configured} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: "alpaca credentials not configured for this org"})

      {:error, reason} ->
        Logger.warning("PortfolioController: upstream fetch failed: #{inspect(reason)}")

        conn
        |> put_status(:bad_gateway)
        |> json(%{ok: false, error: "portfolio fetch failed: #{inspect(reason)}"})
    end
  end

  # Cost basis = avg_entry * qty. `pct_of_book` is expressed against the
  # sum of absolute market values across all held positions rather than
  # account equity — this is the denominator research wants for sizing
  # decisions ("what fraction of my deployed book is this position?"),
  # and it stays meaningful when cash is zero or negative on margin.
  # Rounded to 2dp for display; callers can re-derive raw values from
  # market_value / total_market_value if they need more precision.
  defp build_positions(positions) do
    total =
      positions
      |> Enum.map(&abs_or_zero(&1.market_value))
      |> Enum.sum()

    serialized =
      Enum.map(positions, fn p ->
        cost_basis = cost_basis_for(p)

        pct =
          if total > 0,
            do: Float.round(abs_or_zero(p.market_value) / total * 100.0, 2),
            else: 0.0

        %{
          symbol: p.symbol,
          qty: p.qty,
          side: p.side,
          avg_entry_price: p.avg_entry,
          current_price: p.current_price,
          market_value: p.market_value,
          cost_basis: cost_basis,
          unrealized_pl: p.unrealized_pl,
          unrealized_plpc: p.unrealized_plpc,
          pct_of_book: pct
        }
      end)

    {serialized, total}
  end

  defp cost_basis_for(%{avg_entry: avg, qty: qty})
       when is_number(avg) and is_number(qty) do
    Float.round(avg * qty, 4)
  end

  defp cost_basis_for(_), do: nil

  defp abs_or_zero(n) when is_number(n), do: abs(n)
  defp abs_or_zero(_), do: 0.0

  defp serialize_account(account) do
    %{
      cash: account.cash,
      buying_power: account.buying_power,
      portfolio_value: account.portfolio_value,
      equity: account.equity,
      day_trade_count: account.day_trade_count,
      status: account.status
    }
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
