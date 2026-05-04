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
    POST   /api/v1/trades        — enqueue a trade signal
    GET    /api/v1/trades        — list trades for the authenticated agent
    GET    /api/v1/trades/:id    — get a single trade
    DELETE /api/v1/trades/:id    — cancel an open trade (agent-owned only)
    GET    /api/v1/agents/me     — get agent info + P&L stats
  """

  use KiteAgentHubWeb, :controller

  require Logger

  alias KiteAgentHub.Api.RateLimiter
  alias KiteAgentHub.Billing.LlmUsageLog
  alias KiteAgentHub.{CollectiveIntelligence, Credentials}
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading
  alias KiteAgentHub.TradingPlatforms.AlpacaClient
  alias KiteAgentHub.Workers.{TradeExecutionWorker, PaperExecutionWorker}

  @paper_providers ~w(oanda_practice kalshi)

  @alpaca_order_fields ~w(
    provider order_type type time_in_force limit_price stop_price trail_price trail_percent
    extended_hours order_class take_profit take_profit_limit_price stop_loss
    stop_loss_stop_price stop_loss_price stop_loss_limit_price client_order_id
  )

  @broker_order_fields ~w(
    action order_type type time_in_force timeInForce position_fill positionFill price limit_price
    stop_price price_bound gtd_time trigger_condition take_profit take_profit_price
    stop_loss stop_loss_price stop_loss_limit_price trailing_stop_loss trailing_stop_distance
    client_extensions trade_client_extensions client_order_id client_tag client_comment
    yes_price no_price yes_price_dollars no_price_dollars count count_fp expiration_ts
    buy_max_cost post_only reduce_only self_trade_prevention_type order_group_id
    cancel_order_on_pause subaccount mode token_id
  )

  # ── POST /api/v1/trades ───────────────────────────────────────────────────────

  def create(conn, params) do
    with {:ok, agent} <- authenticate(conn),
         :ok <- require_trading_agent(agent),
         :ok <- RateLimiter.check(agent.id),
         {:ok, job_args, worker} <- build_job(params, agent) do
      case job_args |> worker.new() |> Oban.insert() do
        {:ok, job} ->
          record_byo_usage(agent)

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

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(%{ok: false, error: "agent type is not permitted to execute trades"})

      {:error, :rate_limited} ->
        # 429 body is intentionally generic — no agent.id, bucket
        # counts, or internal state per CyberSec condition (msg 6886).
        conn
        |> put_status(:too_many_requests)
        |> json(%{ok: false, error: "rate limited"})

      {:error, message} when is_binary(message) ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: message})
    end
  end

  # Fire-and-forget billing row — a Repo.insert failure must NOT
  # propagate into the response (CyberSec condition, msg 6886).
  defp record_byo_usage(agent) do
    Task.start(fn ->
      try do
        %LlmUsageLog{}
        |> LlmUsageLog.changeset(%{
          org_id: agent.organization_id,
          agent_id: agent.id,
          provider: "byo",
          source: "byo_rest"
        })
        |> Repo.insert()
      rescue
        e ->
          Logger.warning("TradesController: LlmUsageLog insert raised — #{Exception.message(e)}")
      end
    end)

    :ok
  end

  # Only agents with agent_type == "trading" may submit orders. Research
  # and conversational agents are signal/chat-only by design — this guard
  # mirrors the one already enforced on DELETE /api/v1/broker/orders/:id
  # in broker_orders_controller.ex.
  defp require_trading_agent(%{agent_type: "trading"}), do: :ok
  defp require_trading_agent(_), do: {:error, :forbidden}

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

  # ── DELETE /api/v1/trades/:id ─────────────────────────────────────────────────

  @doc """
  Cancel an open trade. The calling agent must own the trade (enforced
  by `Trading.cancel_trade/2` which returns `:not_found` for anyone
  else — we do not leak existence across agents).

  Idempotent: cancelling a trade that is already in a terminal state
  returns 200 with `already_terminal: true` instead of flipping the
  status again. This lets the agent safely retry on network blips.

  For Alpaca trades, we ALSO forward the cancel to Alpaca
  (`DELETE /v2/orders/{platform_order_id}`) so the order leaves the
  broker book — otherwise a ghost open order keeps blocking the
  ticker via wash-trade rules even after the DB row flips.
  """
  def cancel(conn, %{"id" => id}) do
    with {:ok, agent} <- authenticate(conn) do
      case Trading.cancel_trade(id, agent.id) do
        {:ok, trade} ->
          maybe_cancel_on_broker(trade, agent)

          conn
          |> json(%{ok: true, trade: serialize_trade(trade), already_terminal: false})

        {:ok, :already_terminal, trade} ->
          conn
          |> json(%{ok: true, trade: serialize_trade(trade), already_terminal: true})

        {:error, :not_found} ->
          conn |> put_status(:not_found) |> json(%{ok: false, error: "not found"})

        {:error, _changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{ok: false, error: "failed to cancel"})
      end
    else
      {:error, :unauthorized} ->
        conn |> put_status(:unauthorized) |> json(%{ok: false, error: "invalid api key"})
    end
  end

  # Fire-and-log Alpaca cancel. We don't fail the hub-side cancel if the
  # broker rejects — the DB row is already flipped and the sweep path
  # treats broker 422/404 as idempotent. We do log every outcome so a
  # stuck broker order shows up clearly in the logs.
  defp maybe_cancel_on_broker(%{platform: "alpaca", platform_order_id: order_id}, agent)
       when is_binary(order_id) do
    case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.cancel_order(key_id, secret, order_id, env) do
          {:ok, result} ->
            Logger.info("TradesController: alpaca cancel #{order_id} ok (#{inspect(result)})")

          {:error, reason} ->
            Logger.warning(
              "TradesController: alpaca cancel #{order_id} failed: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "TradesController: alpaca cancel skipped — credentials unavailable: #{inspect(reason)}"
        )
    end
  end

  defp maybe_cancel_on_broker(_trade, _agent), do: :ok

  # ── GET /api/v1/agents/me ─────────────────────────────────────────────────────

  def agent_me(conn, _params) do
    with {:ok, agent} <- authenticate(conn) do
      stats = Trading.agent_pnl_stats(agent.id)
      kci_enabled? = CollectiveIntelligence.enabled_for_org?(agent.organization_id)

      conn
      |> json(%{
        ok: true,
        agent: %{
          id: agent.id,
          name: agent.name,
          status: agent.status,
          agent_type: agent.agent_type,
          wallet_address: agent.wallet_address,
          vault_address: agent.vault_address,
          attestations_enabled: agent.attestations_enabled,
          markets: agent.markets || [],
          collective_intelligence: %{
            enabled: kci_enabled?,
            name: "Kite Collective Intelligence",
            endpoint: "/api/v1/collective-intelligence",
            scope: "workspace",
            consent_version: CollectiveIntelligence.consent_version(),
            reciprocity:
              "Reading shared insights requires opt-in. By enabling KCI you also contribute every settled-trade outcome (anonymized, bucketed). Opt out in Settings to leave."
          }
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

  # Route the inbound trade to the correct Oban worker based on the
  # optional "provider" field. Paper providers (oanda_practice, kalshi)
  # take a separate arg shape and go to PaperExecutionWorker; legacy
  # flows (no provider, or provider not in the allowlist) keep the
  # existing TradeExecutionWorker contract unchanged.
  defp build_job(params, agent) do
    case normalize_provider(Map.get(params, "provider")) do
      p when p in @paper_providers ->
        with {:ok, args} <- validate_paper_params(params, agent, p) do
          {:ok, args, PaperExecutionWorker}
        end

      _ ->
        with {:ok, args} <- validate_trade_params(params, agent) do
          {:ok, args, TradeExecutionWorker}
        end
    end
  end

  defp normalize_provider("oanda"), do: "oanda_practice"
  defp normalize_provider(provider), do: provider

  defp validate_paper_params(params, agent, "kalshi") do
    symbol = params["ticker"] || params["symbol"] || params["market"]
    side = params["side"]
    action = params["action"] || "buy"
    units = parse_units(params["units"] || params["contracts"] || params["count"])

    price =
      params["price"] ||
        params["yes_price"] ||
        params["no_price"] ||
        params["yes_price_dollars"] ||
        params["no_price_dollars"] ||
        params["limit_price"]

    org_id = agent.organization_id

    cond do
      is_nil(symbol) or symbol == "" ->
        {:error, "symbol is required"}

      side not in ["yes", "no"] ->
        {:error, "kalshi side must be yes or no"}

      action not in ["buy", "sell"] ->
        {:error, "kalshi action must be buy or sell"}

      is_nil(units) ->
        {:error, "units must be a positive integer"}

      is_nil(price) ->
        {:error, "kalshi price is required in cents or dollars"}

      is_nil(org_id) ->
        {:error, "agent is not attached to an organization"}

      true ->
        {:ok,
         %{
           "agent_id" => agent.id,
           "organization_id" => org_id,
           "provider" => "kalshi",
           "symbol" => symbol,
           "side" => side,
           "action" => action,
           "units" => units,
           "price" => price
         }
         |> Map.merge(Map.take(params, @broker_order_fields))}
    end
  end

  defp validate_paper_params(params, agent, provider) do
    symbol = params["symbol"] || params["market"]
    side = params["side"]
    units = parse_units(params["units"] || params["contracts"])
    org_id = agent.organization_id

    cond do
      is_nil(symbol) or symbol == "" ->
        {:error, "symbol is required"}

      side not in ["buy", "sell", "yes", "no"] ->
        {:error, "side must be buy, sell, yes, or no"}

      is_nil(units) ->
        {:error, "units must be a positive integer"}

      is_nil(org_id) ->
        {:error, "agent is not attached to an organization"}

      true ->
        {:ok,
         %{
           "agent_id" => agent.id,
           "organization_id" => org_id,
           "provider" => provider,
           "symbol" => symbol,
           "side" => side,
           "units" => units,
           "token_id" => params["token_id"],
           "price" => params["price"],
           "mode" => params["mode"] || "paper"
         }
         |> Map.merge(Map.take(params, @broker_order_fields))}
    end
  end

  defp parse_units(n) when is_integer(n) and n > 0, do: n

  defp parse_units(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp parse_units(_), do: nil

  defp validate_trade_params(params, agent) do
    market = TradeExecutionWorker.normalize_market(params["market"])
    side = params["side"]
    action = params["action"]
    contracts = params["contracts"]
    notional = params["notional"]
    fill_price = params["fill_price"]

    cond do
      is_nil(market) ->
        {:error, "market is required"}

      forex_market?(market) ->
        {:error, "forex trades require provider=oanda_practice and symbol like EUR_USD"}

      is_nil(side) ->
        {:error, "side is required (long or short)"}

      action not in ["buy", "sell"] ->
        {:error, "action must be buy or sell"}

      is_nil(contracts) and is_nil(notional) ->
        {:error, "contracts (units) or notional (USD amount) is required"}

      not is_nil(contracts) and contracts <= 0 ->
        {:error, "contracts must be a positive number"}

      not is_nil(notional) and notional <= 0 ->
        {:error, "notional must be a positive number"}

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
           "notional" => notional,
           "fill_price" => to_string(fill_price),
           "reason" => params["reason"]
         }
         |> Map.merge(Map.take(params, @alpaca_order_fields))}
    end
  end

  defp forex_market?(market) when is_binary(market),
    do: Regex.match?(~r/\A[A-Z]{3}_[A-Z]{3}\z/, market)

  defp forex_market?(_), do: false

  defp serialize_trade(trade) do
    %{
      id: trade.id,
      market: trade.market,
      side: trade.side,
      action: trade.action,
      # `contracts` is now :decimal in the schema (was :integer until
      # 2026-05-01). Jason's default Decimal encoding is a string, but
      # the agent prompt + MCP `get_trades` consumers expect a JSON
      # number. Coerce: integer for whole sizes, float for fractional
      # crypto, so JS callers always see a number.
      contracts: contracts_to_json(trade.contracts),
      fill_price: trade.fill_price,
      notional_usd: trade.notional_usd,
      status: trade.status,
      platform: trade.platform,
      platform_order_id: trade.platform_order_id,
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

  defp contracts_to_json(nil), do: nil

  defp contracts_to_json(%Decimal{} = d) do
    if Decimal.integer?(d), do: Decimal.to_integer(d), else: Decimal.to_float(d)
  end

  defp contracts_to_json(other), do: other
end
