defmodule KiteAgentHub.Workers.PaperExecutionWorker do
  @moduledoc """
  Oban worker that dispatches provider-specific trade jobs to OANDA
  practice and Kalshi. Each dispatch creates a TradeRecord upfront,
  calls the broker API, and settles or fails the record based on the
  response. Settled trades are automatically enqueued for on-chain
  attestation via KiteAttestationWorker.

  Enqueue via:

      %{
        "agent_id"        => agent.id,
        "organization_id" => org.id,
        "provider"        => "oanda_practice" | "kalshi",
        "symbol"          => "EUR_USD" | "KXBTCD-25APR30",
        "side"            => "buy" | "sell" | "yes" | "no",
        "units"           => 100
      }
      |> KiteAgentHub.Workers.PaperExecutionWorker.new()
      |> Oban.insert()

  Guards:
    * provider must be in the allowlist — `"oanda_live"` is actively
      rejected at the entry point.
    * units > 0, symbol non-empty.
    * agent_type must be `"trading"`; non-trading agents are rejected
      before any platform call.
    * Credentials are fetched from the encrypted store inside the
      platform module; job args never carry tokens or account ids.
  """

  use Oban.Worker,
    queue: :paper_execution,
    max_attempts: 3

  require Logger

  alias KiteAgentHub.{Credentials, Repo, Trading, Oanda}
  alias KiteAgentHub.TradingPlatforms.KalshiClient

  @allowed_providers ~w(oanda_practice kalshi)

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: args}) do
    with :ok <- validate_provider(args["provider"]),
         :ok <- validate_symbol(args["symbol"]),
         :ok <- validate_units(args["units"]),
         {:ok, agent} <- load_agent(args["agent_id"]) do
      # Establish RLS context before any trade record writes — mirrors
      # the pattern used by TradeExecutionWorker / AlpacaSettlementWorker.
      # Without this, Trading.create_trade inserts run with no
      # `app.current_user_id` set, which propagates inconsistent rows
      # through the {:trade_created, ...} PubSub broadcast and crashes
      # the dashboard's handle_info → triggers a socket reconnect loop.
      case Repo.owner_user_id_for_agent(agent.id) do
        nil ->
          Logger.warning(
            "PaperExecutionWorker job=#{job_id} no owner_user_id for agent #{agent.id} — skipping"
          )

          {:error, :no_owner}

        owner_user_id ->
          Repo.with_user(owner_user_id, fn -> dispatch(agent, args, job_id) end)
      end
    else
      {:error, reason} = err ->
        Logger.warning(
          "PaperExecutionWorker job=#{job_id} provider=#{inspect(args["provider"])} rejected: #{inspect(reason)}"
        )

        err
    end
  end

  # ── Validation ─────────────────────────────────────────────────────────────

  defp validate_provider(p) when p in @allowed_providers, do: :ok
  defp validate_provider("oanda_live"), do: {:error, :live_dispatch_not_allowed}
  defp validate_provider(_), do: {:error, :invalid_provider}

  defp validate_symbol(s) when is_binary(s) and byte_size(s) > 0, do: :ok
  defp validate_symbol(_), do: {:error, :invalid_symbol}

  defp validate_units(n) when is_integer(n) and n > 0, do: :ok

  defp validate_units(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i > 0 -> :ok
      _ -> {:error, :invalid_units}
    end
  end

  defp validate_units(_), do: {:error, :invalid_units}

  defp load_agent(nil), do: {:error, :missing_agent_id}

  defp load_agent(agent_id) do
    try do
      {:ok, Trading.get_agent!(agent_id)}
    rescue
      _ -> {:error, :agent_not_found}
    end
  end

  # ── Dispatch ───────────────────────────────────────────────────────────────

  defp dispatch(
         %{agent_type: "trading"} = agent,
         %{"provider" => "oanda_practice"} = args,
         job_id
       ) do
    org_id = args["organization_id"]
    symbol = args["symbol"]
    raw_units = parse_units!(args["units"])
    signed = signed_units(raw_units, args["side"])

    # Open a TradeRecord upfront so the audit trail exists even if the
    # OANDA call fails. fill_price is a placeholder until OANDA returns
    # the actual fill — the schema requires it on insert. The price
    # field is overwritten from orderFillTransaction.price on settle.
    case create_oanda_trade(agent, args, raw_units) do
      {:ok, trade} ->
        case Oanda.place_practice_order(agent, org_id, symbol, signed, oanda_opts(args)) do
          {:ok, body} ->
            handle_oanda_response(trade, body, job_id)

          {:error, reason} = err ->
            Logger.warning(
              "PaperExecutionWorker job=#{job_id} provider=oanda_practice transport failed: #{inspect(reason)}"
            )

            mark_trade_failed(trade, "oanda transport error: #{inspect(reason)}")
            err
        end

      {:error, changeset} ->
        Logger.error(
          "PaperExecutionWorker job=#{job_id} provider=oanda_practice trade create failed: #{inspect(changeset.errors)}"
        )

        {:error, :trade_create_failed}
    end
  end

  defp dispatch(%{agent_type: "trading"} = agent, %{"provider" => "kalshi"} = args, job_id) do
    org_id = args["organization_id"] || agent.organization_id
    symbol = args["symbol"]
    side = args["side"]
    units = parse_units!(args["units"])

    price =
      args["price"] ||
        args["yes_price"] ||
        args["no_price"] ||
        args["yes_price_dollars"] ||
        args["no_price_dollars"] ||
        args["limit_price"]

    case create_kalshi_trade(agent, args, units, price) do
      {:ok, trade} ->
        with {:ok, {key_id, pem, env}} <- Credentials.fetch_secret_with_env(org_id, :kalshi),
             {:ok, order} <-
               KalshiClient.place_order(
                 key_id,
                 pem,
                 symbol,
                 side,
                 units,
                 price,
                 env,
                 kalshi_opts(args)
               ) do
          handle_kalshi_response(trade, order, job_id)
        else
          {:error, reason} = err ->
            Logger.warning(
              "PaperExecutionWorker job=#{job_id} provider=kalshi failed: #{inspect(reason)}"
            )

            mark_trade_failed(trade, "kalshi error: #{inspect(reason)}")
            err
        end

      {:error, changeset} ->
        Logger.error(
          "PaperExecutionWorker job=#{job_id} provider=kalshi trade create failed: #{inspect(changeset.errors)}"
        )

        {:error, :trade_create_failed}
    end
  end

  defp dispatch(%{agent_type: _}, _args, job_id) do
    Logger.warning("PaperExecutionWorker job=#{job_id} rejected: not a trading agent")
    {:error, :not_a_trading_agent}
  end

  # OANDA expects signed units — positive for buy, negative for sell.
  defp signed_units(n, side) when is_integer(n) do
    case side do
      "sell" -> -abs(n)
      _ -> abs(n)
    end
  end

  defp parse_units!(n) when is_integer(n), do: n
  defp parse_units!(n) when is_binary(n), do: String.to_integer(n)

  @kalshi_order_fields ~w(
    action order_type type time_in_force yes_price no_price yes_price_dollars no_price_dollars
    count_fp expiration_ts buy_max_cost post_only reduce_only self_trade_prevention_type
    order_group_id cancel_order_on_pause subaccount client_order_id
  )

  defp kalshi_opts(args), do: Map.take(args, @kalshi_order_fields)

  @oanda_order_fields ~w(
    order_type type time_in_force timeInForce position_fill positionFill price limit_price
    stop_price price_bound gtd_time trigger_condition take_profit take_profit_price
    stop_loss stop_loss_price trailing_stop_loss trailing_stop_distance
    client_extensions trade_client_extensions client_order_id client_tag client_comment
  )

  defp oanda_opts(args), do: Map.take(args, @oanda_order_fields)

  # ── OANDA TradeRecord lifecycle ────────────────────────────────────────────

  defp create_oanda_trade(agent, args, raw_units) do
    placeholder_price =
      case args["price"] do
        p when is_binary(p) and p != "" ->
          case Decimal.parse(p) do
            {dec, _} -> dec
            :error -> Decimal.new(0)
          end

        _ ->
          Decimal.new(0)
      end

    side = if args["side"] == "sell", do: "short", else: "long"
    action = if args["side"] == "sell", do: "sell", else: "buy"

    Trading.create_trade(%{
      kite_agent_id: agent.id,
      market: args["symbol"],
      side: side,
      action: action,
      contracts: raw_units,
      fill_price: placeholder_price,
      status: "open",
      source: "oban",
      reason: args["reason"],
      platform: "oanda"
    })
  end

  # OANDA market+FOK orders fill or cancel synchronously. The response
  # body is documented at developer.oanda.com/rest-live-v20/transaction-df/
  # We look for orderFillTransaction (filled) or orderCancelTransaction
  # (rejected, e.g. FOK couldn't fill at the requested size). Anything
  # else leaves the trade open — limit/stop orders still need the future
  # OandaSettlementWorker that polls /accounts/{id}/orders/{id}.
  defp handle_oanda_response(trade, body, job_id) when is_map(body) do
    cond do
      fill = body["orderFillTransaction"] ->
        settle_oanda_trade(trade, fill, job_id)

      cancel = body["orderCancelTransaction"] ->
        reason = cancel["reason"] || "OANDA cancelled"
        Logger.info("PaperExecutionWorker job=#{job_id} provider=oanda_practice cancelled: #{reason}")
        mark_trade_failed(trade, "oanda cancel: #{reason}")
        {:error, {:oanda_cancel, reason}}

      true ->
        Logger.info(
          "PaperExecutionWorker job=#{job_id} provider=oanda_practice accepted (no synchronous fill) — trade left open"
        )

        {:ok, trade}
    end
  end

  defp settle_oanda_trade(trade, fill, job_id) do
    fill_price = parse_fill_price(fill["price"]) || trade.fill_price
    fill_units = parse_fill_units(fill["units"]) || trade.contracts
    order_id = fill["orderID"] || fill["id"]

    Logger.info(
      "PaperExecutionWorker job=#{job_id} provider=oanda_practice FILLED — #{fill_units} @ #{fill_price}"
    )

    update_attrs =
      %{
        fill_price: fill_price,
        contracts: fill_units,
        notional_usd: Decimal.mult(Decimal.new(fill_units), fill_price)
      }
      |> maybe_put_order_id(order_id)

    with {:ok, updated} <- Trading.update_trade(trade, update_attrs),
         {:ok, settled} <- Trading.settle_trade(updated, Decimal.new(0)) do
      enqueue_attestation(settled)
      {:ok, settled}
    else
      {:error, reason} ->
        Logger.error(
          "PaperExecutionWorker job=#{job_id} provider=oanda_practice settle failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_trade_failed(trade, reason) when is_binary(reason) do
    Trading.update_trade(trade, %{status: "failed", reason: reason})
  end

  defp parse_fill_price(price) when is_binary(price) do
    case Decimal.parse(price) do
      {dec, _} -> dec
      :error -> nil
    end
  end

  defp parse_fill_price(_), do: nil

  defp parse_fill_units(units) when is_binary(units) do
    case Integer.parse(units) do
      {n, _} -> abs(n)
      :error -> nil
    end
  end

  defp parse_fill_units(units) when is_integer(units), do: abs(units)
  defp parse_fill_units(_), do: nil

  defp maybe_put_order_id(attrs, nil), do: attrs
  defp maybe_put_order_id(attrs, id), do: Map.put(attrs, :platform_order_id, to_string(id))

  # ── Kalshi TradeRecord lifecycle ────────────────────────────────────────────

  defp create_kalshi_trade(agent, args, units, price) do
    fill_price =
      case price do
        p when is_binary(p) and p != "" ->
          case Decimal.parse(p) do
            {dec, _} -> dec
            :error -> Decimal.new(0)
          end

        p when is_integer(p) ->
          Decimal.new(p)

        _ ->
          Decimal.new(0)
      end

    side = args["side"] || "yes"
    action = if side in ["no", "sell"], do: "sell", else: "buy"

    Trading.create_trade(%{
      kite_agent_id: agent.id,
      market: args["symbol"],
      side: side,
      action: action,
      contracts: units,
      fill_price: fill_price,
      status: "open",
      source: "oban",
      reason: args["reason"],
      platform: "kalshi"
    })
  end

  # Kalshi orders can be "executed" (filled immediately) or "resting"
  # (limit order waiting to match). Executed orders settle and attest
  # synchronously; resting orders stay open for a future settlement
  # worker to poll.
  #
  # A "canceled" response from an IOC order can still carry partial
  # fills — `taker_fill_count > 0` means N contracts hit makers before
  # the rest got cancelled. We settle that filled portion at the actual
  # average fill price and only mark the trade failed when zero
  # contracts cleared.
  defp handle_kalshi_response(trade, order, job_id) do
    update_attrs = maybe_put_order_id(%{}, order.id)
    filled = Map.get(order, :taker_fill_count, 0)

    case order.status do
      "executed" ->
        Logger.info(
          "PaperExecutionWorker job=#{job_id} provider=kalshi FILLED order=#{order.id} count=#{filled}"
        )

        attrs = maybe_put_partial_fill(update_attrs, order, trade)
        settle_kalshi(trade, attrs, job_id, order.id)

      status when status in ["canceled", "cancelled"] and filled > 0 ->
        Logger.info(
          "PaperExecutionWorker job=#{job_id} provider=kalshi PARTIAL FILL order=#{order.id} filled=#{filled}/#{order.count}"
        )

        attrs = maybe_put_partial_fill(update_attrs, order, trade)
        settle_kalshi(trade, attrs, job_id, order.id)

      status when status in ["canceled", "cancelled"] ->
        limit_cents = order_limit_cents(order)
        reason = "kalshi cancelled — 0 of #{order.count || trade.contracts} filled at #{limit_cents}c (likely IOC un-marketable)"

        Logger.info(
          "PaperExecutionWorker job=#{job_id} provider=kalshi cancelled order=#{order.id} reason=#{reason}"
        )

        mark_trade_failed(trade, reason)
        {:error, :kalshi_cancelled}

      status ->
        Logger.info(
          "PaperExecutionWorker job=#{job_id} provider=kalshi order=#{order.id} status=#{status} — trade left open"
        )

        Trading.update_trade(trade, update_attrs)
    end
  end

  defp settle_kalshi(trade, attrs, job_id, order_id) do
    with {:ok, updated} <- Trading.update_trade(trade, attrs),
         {:ok, settled} <- Trading.settle_trade(updated, Decimal.new(0)) do
      enqueue_attestation(settled)
      {:ok, settled}
    else
      {:error, reason} ->
        Logger.error(
          "PaperExecutionWorker job=#{job_id} provider=kalshi settle failed order=#{order_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # When Kalshi reports a partial (or full) taker fill, the trade row
  # should reflect what actually cleared — not what we asked for.
  # taker_fill_cost is total cents across all taker fills, so
  # avg fill price (dollars) = cost / count / 100.
  defp maybe_put_partial_fill(attrs, order, trade) do
    filled = Map.get(order, :taker_fill_count, 0)
    cost_cents = Map.get(order, :taker_fill_cost, 0)

    cond do
      filled <= 0 ->
        attrs

      cost_cents > 0 ->
        avg = Decimal.div(Decimal.new(cost_cents), Decimal.new(filled * 100))

        attrs
        |> Map.put(:contracts, Decimal.new(filled))
        |> Map.put(:fill_price, avg)

      true ->
        # Filled but no cost reported — keep existing fill_price, just
        # update the contracts count so settle math is honest.
        Map.put(attrs, :contracts, Decimal.new(filled))
        |> tap(fn _ ->
          Logger.warning(
            "PaperExecutionWorker provider=kalshi partial fill missing taker_fill_cost trade=#{trade.id}"
          )
        end)
    end
  end

  defp order_limit_cents(order) do
    case Map.get(order, :side) do
      "no" -> Map.get(order, :no_price)
      _ -> Map.get(order, :yes_price)
    end
  end

  # KiteAttestationWorker mirrors the Alpaca settlement path — the worker
  # is idempotent (skips if attestation_tx_hash already set) so any retry
  # is safe.
  defp enqueue_attestation(%{id: trade_id}) do
    %{trade_id: trade_id}
    |> KiteAgentHub.Workers.KiteAttestationWorker.new()
    |> Oban.insert()
  end
end
