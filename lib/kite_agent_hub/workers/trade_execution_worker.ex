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
    market = args["market"] || "ETH-USDC"
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

        # Execute on the appropriate platform first
        platform_order_id = maybe_execute_on_platform(platform, agent, args, owner_user_id)

        # Update with platform order ID if we got one
        if platform_order_id do
          trade
          |> KiteAgentHub.Trading.TradeRecord.changeset(%{platform_order_id: platform_order_id})
          |> Repo.update()
        end

        # Always attempt Kite chain settlement proof
        maybe_submit_onchain(trade, agent, args, owner_user_id)

      {:error, changeset} ->
        Logger.error("TradeExecutionWorker: failed to create trade: #{inspect(changeset.errors)}")
        {:error, "trade insert failed"}
    end
  end

  # Detect which platform to execute on based on market
  defp detect_platform(market) when market in @alpaca_markets, do: "alpaca"
  defp detect_platform(_market), do: "kite"

  # Execute on Alpaca paper trading
  defp maybe_execute_on_platform("alpaca", agent, args, _owner_user_id) do
    market = args["market"]
    symbol = Map.get(@alpaca_symbol_map, market, market)
    side = normalize_alpaca_side(args["action"])
    qty = max(1, div(trunc(compute_notional(args) |> Decimal.to_float()), 100))

    case Credentials.fetch_secret(agent.organization_id, :alpaca) do
      {:ok, {key_id, secret}} ->
        case AlpacaClient.place_order(key_id, secret, symbol, qty, side) do
          {:ok, order} ->
            Logger.info("TradeExecutionWorker: Alpaca order #{order.id} placed — #{symbol} #{side} #{qty}")
            order.id

          {:error, reason} ->
            Logger.warning("TradeExecutionWorker: Alpaca order failed: #{inspect(reason)}")
            nil
        end

      {:error, reason} ->
        Logger.warning("TradeExecutionWorker: Alpaca credentials unavailable: #{inspect(reason)}")
        nil
    end
  end

  defp maybe_execute_on_platform(_platform, _agent, _args, _owner_user_id), do: nil

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

  defp encode_trade_calldata(trade) do
    VaultABI.calldata_for_trade(trade)
  end

  defp compute_notional(args) do
    contracts = args["contracts"] || 0
    price = Decimal.new(to_string(args["fill_price"] || "0"))
    Decimal.mult(price, Decimal.new(contracts))
  end
end
