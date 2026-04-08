defmodule KiteAgentHub.Workers.TradeExecutionWorker do
  @moduledoc """
  Oban worker that executes a trade signal across platforms.

  Enqueue via:

      %{
        "agent_id" => agent.id,
        "market"   => "ETH-USDC",
        "side"     => "long",
        "action"   => "buy",
        "contracts" => 10,
        "fill_price" => "3250.00"
      }
      |> KiteAgentHub.Workers.TradeExecutionWorker.new()
      |> Oban.insert()

  The worker:
  1. Loads the agent and verifies it is active and not paused.
  2. Checks per-trade and daily spend limits.
  3. Inserts a TradeRecord in "open" status.
  4. Routes execution to the correct platform (Kite chain, Alpaca, Kalshi) based on market.
  5. Submits to Kite chain for settlement proof (always).
  6. Updates trade_id_onchain / tx_hash / platform_order_id once confirmed.
  """

  use Oban.Worker,
    queue: :trade_execution,
    max_attempts: 3,
    unique: [period: 30, fields: [:args]]

  require Logger

  alias KiteAgentHub.{Trading, Repo, Orgs}
  alias KiteAgentHub.Kite.{RPC, TxSigner, VaultABI, GaslessClient}
  alias KiteAgentHub.Credentials
  alias KiteAgentHub.TradingPlatforms.AlpacaClient

  # Markets routed to Alpaca paper trading (crypto + equities)
  @alpaca_markets ~w(ETH-USDC BTC-USDC SOL-USDC ETHUSD BTCUSD SOLUSD SPY QQQ AAPL TSLA)

  # Alpaca symbol mapping from Kite market notation
  @alpaca_symbol_map %{
    "ETH-USDC" => "ETHUSD",
    "BTC-USDC" => "BTCUSD",
    "SOL-USDC" => "SOLUSD"
  }

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    agent_id = args["agent_id"]
    agent = Trading.get_agent!(agent_id)

    cond do
      agent.status != "active" ->
        Logger.warning("TradeExecutionWorker: agent #{agent_id} is #{agent.status}, skipping")
        {:cancel, "agent not active"}

      true ->
        owner_user_id = Orgs.get_org_owner_user_id(agent.organization_id)
        Repo.with_user(owner_user_id, fn -> execute_trade(agent, args, owner_user_id) end)
    end
  end

  defp execute_trade(agent, args, owner_user_id) do
    # Defense in depth: TradesController already runs normalize_market/1
    # before enqueuing, but AgentRunner (rule_based_strategy + signal_engine)
    # enqueues TradeExecutionWorker directly without going through the
    # controller. Re-running normalization here means malformed markets
    # never reach detect_platform/1 regardless of how the job was queued.
    market = normalize_market(args["market"]) || "ETH-USDC"
    platform = detect_platform(market)

    trade_attrs = %{
      kite_agent_id: agent.id,
      market: market,
      side: args["side"],
      action: args["action"],
      contracts: args["contracts"],
      fill_price: Decimal.new(to_string(args["fill_price"])),
      notional_usd: compute_notional(args),
      status: "open",
      source: "oban",
      reason: args["reason"],
      platform: platform
    }

    case Trading.create_trade(trade_attrs) do
      {:ok, trade} ->
        Logger.info("TradeExecutionWorker: trade #{trade.id} created for agent #{agent.id} on #{platform}")

        case maybe_execute_on_platform(platform, agent, args, owner_user_id) do
          {:ok, platform_order_id} ->
            trade
            |> KiteAgentHub.Trading.TradeRecord.changeset(%{platform_order_id: platform_order_id})
            |> Repo.update()

          {:error, reason} ->
            # Alpaca rejected the order (insufficient qty, market closed,
            # invalid symbol, etc.). Flip the trade to "failed" with the
            # broker's error stashed in the reason field so the agent can
            # see what went wrong on the next GET /trades. Don't try to
            # write a non-string reason — Alpaca returns nested maps that
            # would explode the string column.
            trade
            |> KiteAgentHub.Trading.TradeRecord.changeset(%{
              status: "failed",
              reason: format_failure_reason(reason)
            })
            |> Repo.update()

          :noop ->
            :ok
        end

        # Kite on-chain settlement proof is only meaningful for trades
        # that were intended to settle on Kite chain. Alpaca trades
        # complete entirely through the broker — running the EVM signing
        # path on top would (a) hit a missing private key error and
        # spam logs, (b) waste an RPC call, and (c) confuse the trade
        # row with an unrelated tx_hash. Short-circuit on platform.
        if platform != "alpaca" do
          maybe_submit_onchain(trade, agent, args, owner_user_id)
        end

      {:error, changeset} ->
        Logger.error("TradeExecutionWorker: failed to create trade: #{inspect(changeset.errors)}")
        {:error, "trade insert failed"}
    end
  end

  defp format_failure_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp format_failure_reason(reason), do: reason |> inspect() |> String.slice(0, 500)

  # Detect which platform to execute on based on market.
  #
  # The hardcoded @alpaca_markets list always wins (covers crypto pairs
  # like ETH-USDC and the original equity allowlist), but anything that
  # *looks* like a standard US equity ticker — uppercase letters only,
  # 1 to 5 chars — is also auto-routed to Alpaca. Without this, every
  # ticker the agent picks up dynamically (GLD, NVDA, MSFT, AMD, ...)
  # falls through to platform="kite", which has no Alpaca order
  # placement and leaves the trade row stranded at status="open"
  # forever. The whitelist alone was the bottleneck the agent kept
  # hitting in prod.
  defp detect_platform(market) when market in @alpaca_markets, do: "alpaca"

  defp detect_platform(market) when is_binary(market) do
    if Regex.match?(~r/\A[A-Z]{1,5}\z/, market) do
      "alpaca"
    else
      "kite"
    end
  end

  defp detect_platform(_market), do: "kite"

  # Execute on Alpaca. Returns:
  #   {:ok, order_id}     — order accepted by Alpaca, id stored on the trade row
  #   {:error, reason}    — Alpaca rejected (403 insufficient qty, 422, etc.)
  #                         OR credentials missing. Caller flips trade to failed.
  #   :noop               — non-Alpaca platform, do nothing here
  defp maybe_execute_on_platform("alpaca", agent, args, _owner_user_id) do
    market = args["market"]
    symbol = Map.get(@alpaca_symbol_map, market, market)
    side = normalize_alpaca_side(args["action"])

    # qty is the agent's intended share/unit count, passed through to
    # Alpaca as-is. The previous formula was
    #   max(1, div(trunc(notional), 100))
    # which assumed every asset trades at ~$100/share — wildly wrong
    # for SPY (~$520) and catastrophically wrong for crypto pairs like
    # BTCUSD (~$60k) where it would have requested 600 BTC for what
    # the agent thought was a $250 trade. PR #94: trust the agent's
    # explicit `contracts` value and let Alpaca enforce position size
    # limits server-side.
    qty = parse_qty(args["contracts"])

    case Credentials.fetch_secret_with_env(agent.organization_id, :alpaca) do
      {:ok, {key_id, secret, env}} ->
        case AlpacaClient.place_order(key_id, secret, symbol, qty, side, env) do
          {:ok, order} ->
            Logger.info(
              "TradeExecutionWorker: Alpaca order #{order.id} placed — #{symbol} #{side} #{qty} (env=#{env})"
            )

            {:ok, order.id}

          {:error, reason} ->
            Logger.warning(
              "TradeExecutionWorker: Alpaca order failed (env=#{env}): #{inspect(reason)}"
            )

            {:error, reason}
        end

      {:error, reason} ->
        Logger.warning("TradeExecutionWorker: Alpaca credentials unavailable: #{inspect(reason)}")
        {:error, "alpaca credentials unavailable"}
    end
  end

  defp maybe_execute_on_platform(_platform, _agent, _args, _owner_user_id), do: :noop

  defp normalize_alpaca_side("buy"), do: "buy"
  defp normalize_alpaca_side("sell"), do: "sell"
  defp normalize_alpaca_side(_), do: "buy"

  defp maybe_submit_onchain(trade, agent, args, owner_user_id) do
    signed_tx = args["signed_tx_hex"]
    private_key = Application.get_env(:kite_agent_hub, :agent_private_key, "")
    network = if agent.chain_id == 2366, do: :mainnet, else: :testnet

    cond do
      signed_tx ->
        submit_tx(trade, signed_tx, owner_user_id)

      private_key != "" and agent.vault_address ->
        maybe_gasless_deposit(agent, private_key, network)
        sign_and_submit(trade, agent, private_key, owner_user_id)

      true ->
        Logger.info(
          "TradeExecutionWorker: no signing key — trade #{trade.id} recorded as open intent"
        )

        :ok
    end
  end

  # Attempt a gasless deposit to ensure the vault has funds before the trade.
  # Non-blocking: logs and continues even if gasless deposit is unavailable.
  defp maybe_gasless_deposit(agent, private_key, network) do
    token = GaslessClient.token_info(network)
    min_deposit = round(1 * :math.pow(10, token.decimals))

    case GaslessClient.transfer(private_key, agent.vault_address, min_deposit, network) do
      {:ok, tx_hash} ->
        Logger.info("GaslessClient: vault deposit submitted — tx=#{tx_hash}")

      {:error, reason} ->
        Logger.debug("GaslessClient: gasless deposit skipped — #{inspect(reason)}")
    end
  end

  defp submit_tx(trade, signed_tx_hex, owner_user_id) do
    case RPC.send_raw_transaction(signed_tx_hex) do
      {:ok, tx_hash} ->
        Logger.info("TradeExecutionWorker: trade #{trade.id} submitted, tx=#{tx_hash}")

        trade
        |> KiteAgentHub.Trading.TradeRecord.changeset(%{tx_hash: tx_hash})
        |> Repo.update()

        enqueue_settlement(trade.id, tx_hash, owner_user_id)
        :ok

      {:error, reason} ->
        Logger.error("TradeExecutionWorker: tx submission failed: #{inspect(reason)}")
        {:error, "tx_submit_failed"}
    end
  end

  defp sign_and_submit(trade, agent, private_key, owner_user_id) do
    case RPC.get_transaction_count(agent.vault_address) do
      {:ok, nonce} ->
        case RPC.gas_price() do
          {:ok, gas_price} ->
            tx = %{
              nonce: nonce,
              gas_price: gas_price,
              gas_limit: 100_000,
              to: agent.vault_address,
              value: 0,
              data: encode_trade_calldata(trade)
            }

            case TxSigner.sign(tx, private_key, chain_id: agent.chain_id || 2368) do
              {:ok, signed_hex} ->
                submit_tx(trade, signed_hex, owner_user_id)

              {:error, reason} ->
                Logger.error("TradeExecutionWorker: signing failed: #{inspect(reason)}")
                {:error, "signing_failed"}
            end

          {:error, reason} ->
            Logger.error("TradeExecutionWorker: gas_price fetch failed: #{inspect(reason)}")
            {:error, "gas_price_failed"}
        end

      {:error, reason} ->
        Logger.error("TradeExecutionWorker: nonce fetch failed: #{inspect(reason)}")
        {:error, "nonce_failed"}
    end
  end

  defp enqueue_settlement(trade_id, tx_hash, owner_user_id) do
    %{"trade_id" => trade_id, "tx_hash" => tx_hash, "owner_user_id" => owner_user_id}
    |> KiteAgentHub.Workers.SettlementWorker.new(schedule_in: 15)
    |> Oban.insert()
  end

  @doc """
  Normalize a market string into the canonical KAH form before routing.

  Public so TradesController and any other enqueue path (AgentRunner,
  RuleBasedStrategy, SignalEngine, future internal callers) can call
  the same helper. Belt-and-suspenders fix from PR #93 review:
  controller-only normalization left a gap for jobs queued from inside
  the app.

  Steps:
    1. Trim surrounding whitespace
    2. Uppercase ("btcusd" → "BTCUSD")
    3. Strip slashes ("BTC/USD" → "BTCUSD")
    4. Strip inner whitespace ("BTC USD" → "BTCUSD")
    5. Empty result → nil so the existing required-field check fires

  Deliberately does NOT touch dashes — "ETH-USDC" is a real KAH market
  name and stripping the dash would break @alpaca_markets routing.
  """
  def normalize_market(nil), do: nil
  def normalize_market(market) when not is_binary(market), do: nil

  def normalize_market(market) do
    market
    |> String.trim()
    |> String.upcase()
    |> String.replace("/", "")
    |> String.replace(~r/\s+/, "")
    |> case do
      "" -> nil
      m -> m
    end
  end

  defp encode_trade_calldata(trade) do
    VaultABI.calldata_for_trade(trade)
  end

  defp compute_notional(args) do
    contracts = args["contracts"] || 0
    price = Decimal.new(to_string(args["fill_price"] || "0"))
    Decimal.mult(price, Decimal.new(contracts))
  end

  # Coerce the agent's `contracts` field into a positive integer for
  # Alpaca's qty parameter. Accepts integers, floats (for fractional
  # crypto orders), or numeric strings. Falls back to 1 on garbage so
  # the order is at least valid (Alpaca will reject anything that
  # exceeds the agent's actual buying power).
  defp parse_qty(qty) when is_integer(qty) and qty > 0, do: qty
  defp parse_qty(qty) when is_float(qty) and qty > 0, do: qty
  defp parse_qty(qty) when is_binary(qty) do
    case Float.parse(qty) do
      {f, _} when f > 0 -> f
      _ -> 1
    end
  end
  defp parse_qty(_), do: 1
end
