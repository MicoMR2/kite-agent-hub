defmodule KiteAgentHubWeb.API.TradesController do
  @moduledoc """
  JSON API for programmatic trade submission and status queries.

  All endpoints require the secret agent api_token sent as:
    Authorization: Bearer <agent_api_token>

  ## Security note

  Earlier versions of this controller accepted the agent's
  `wallet_address` as a fallback credential. That was an auth bypass:
  wallet addresses are public on-chain, so anyone who could read the
  chain could impersonate any agent. That fallback has been removed —
  only the secret api_token is accepted.

  Endpoints:
    POST /api/v1/trades        — enqueue a trade signal
    GET  /api/v1/trades        — list trades for the authenticated agent
    GET  /api/v1/trades/:id    — get a single trade
    GET  /api/v1/agents/me     — get agent info + P&L stats
  """

  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Workers.TradeExecutionWorker

  # ── POST /api/v1/trades ───────────────────────────────────────────────────────

  def create(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         {:ok, job_args} <- validate_trade_params(params, agent) do
      case job_args |> TradeExecutionWorker.new() |> Oban.insert() do
        {:ok, job} ->
          conn
          |> put_status(:accepted)
          |> json(%{ok: true, job_id: job.id, status: "queued"})

        {:error, reason} ->
          Logger.error("API TradesController: Oban insert failed: #{inspect(reason)}")

          conn
          |> put_status(:unprocessable_entity)
          |> json(%{ok: false, error: "failed to enqueue trade"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})

      {:error, message} when is_binary(message) ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: message})
    end
  end

  # ── GET /api/v1/trades ────────────────────────────────────────────────────────

  def index(conn, params) do
    with {:ok, agent} <- authenticate(conn) do
      status = params["status"]
      limit = min(String.to_integer(params["limit"] || "50"), 200)

      opts = [limit: limit] ++ if(status, do: [status: status], else: [])
      trades = Trading.list_trades(agent.id, opts)

      conn |> json(%{ok: true, trades: Enum.map(trades, &serialize_trade/1)})
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  # ── GET /api/v1/trades/:id ────────────────────────────────────────────────────

  def show(conn, %{"id" => id}) do
    with {:ok, agent} <- authenticate(conn) do
      case Trading.get_trade_for_agent(id, agent.id) do
        nil ->
          conn |> put_status(:not_found) |> json(%{ok: false, error: "not found"})

        trade ->
          conn |> json(%{ok: true, trade: serialize_trade(trade)})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  # ── GET /api/v1/agents/me ─────────────────────────────────────────────────────

  def agent_me(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      stats = Trading.agent_pnl_stats(agent.id)

      conn
      |> json(%{
        ok: true,
        agent: %{
          id: agent.id,
          name: agent.name,
          status: agent.status,
          wallet_address: agent.wallet_address,
          vault_address: agent.vault_address
        },
        stats: stats
      })
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────────

  # Auth is via the secret agent api_token ONLY. Wallet addresses are
  # public on-chain and must never be accepted as a credential.
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

  defp validate_trade_params(params, agent) do
    market = TradeExecutionWorker.normalize_market(params["market"])
    side = params["side"]
    action = params["action"]
    contracts = params["contracts"]
    fill_price = params["fill_price"]

    cond do
      is_nil(market) ->
        {:error, "market is required"}

      is_nil(side) ->
        {:error, "side is required (long or short)"}

      action not in ["buy", "sell"] ->
        {:error, "action must be buy or sell"}

      is_nil(contracts) or contracts <= 0 ->
        {:error, "contracts must be a positive integer"}

      is_nil(fill_price) ->
        {:error, "fill_price is required"}

      true ->
        {:ok,
         %{
           "agent_id" => agent.id,
           "market" => market,
           "side" => side,
           "action" => action,
           "contracts" => contracts,
           "fill_price" => to_string(fill_price),
           "reason" => params["reason"]
         }}
    end
  end


  defp serialize_trade(trade) do
    %{
      id: trade.id,
      market: trade.market,
      side: trade.side,
      action: trade.action,
      contracts: trade.contracts,
      fill_price: trade.fill_price,
      notional_usd: trade.notional_usd,
      status: trade.status,
      realized_pnl: trade.realized_pnl,
      tx_hash: trade.tx_hash,
      # PR #107: expose the Kite chain attestation tx hash so the agent
      # (and any downstream API consumer) can see whether a settled
      # trade has been attested on-chain yet, plus the explorer URL
      # for that proof. Without this, the agent was reading the older
      # `tx_hash` field (which is for the original on-chain trade
      # intent record, separate from attestation) and getting null.
      attestation_tx_hash: trade.attestation_tx_hash,
      attestation_explorer_url:
        if(trade.attestation_tx_hash,
          do: "https://testnet.kitescan.ai/tx/" <> trade.attestation_tx_hash
        ),
      reason: trade.reason,
      inserted_at: trade.inserted_at
    }
  end
end
