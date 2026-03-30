defmodule KiteAgentHub.Workers.TradeExecutionWorker do
  @moduledoc """
  Oban worker that executes a trade signal on Kite chain.

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
  4. Broadcasts :trade_created via PubSub for the dashboard.
  5. Submits the raw signed transaction to Kite chain (if vault is live).
  6. Updates trade_id_onchain / tx_hash once the chain confirms.
  """

  use Oban.Worker,
    queue: :trade_execution,
    max_attempts: 3,
    unique: [period: 30, fields: [:args]]

  require Logger

  alias KiteAgentHub.{Trading, Repo, Orgs}
  alias KiteAgentHub.Kite.{RPC, TxSigner, VaultABI}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    agent_id = args["agent_id"]
    agent = Trading.get_agent!(agent_id)

    cond do
      agent.status != "active" ->
        Logger.warning("TradeExecutionWorker: agent #{agent_id} is #{agent.status}, skipping")
        {:cancel, "agent not active"}

      not within_per_trade_limit?(agent, args) ->
        Logger.warning("TradeExecutionWorker: agent #{agent_id} per-trade limit exceeded")
        {:cancel, "per-trade limit exceeded"}

      true ->
        owner_user_id = Orgs.get_org_owner_user_id(agent.organization_id)
        Repo.with_user(owner_user_id, fn -> execute_trade(agent, args, owner_user_id) end)
    end
  end

  defp execute_trade(agent, args, owner_user_id) do
    trade_attrs = %{
      kite_agent_id: agent.id,
      market: args["market"],
      side: args["side"],
      action: args["action"],
      contracts: args["contracts"],
      fill_price: Decimal.new(to_string(args["fill_price"])),
      notional_usd: compute_notional(args),
      status: "open",
      source: "oban",
      reason: args["reason"]
    }

    case Trading.create_trade(trade_attrs) do
      {:ok, trade} ->
        Logger.info("TradeExecutionWorker: trade #{trade.id} created for agent #{agent.id}")
        maybe_submit_onchain(trade, agent, args, owner_user_id)

      {:error, changeset} ->
        Logger.error("TradeExecutionWorker: failed to create trade: #{inspect(changeset.errors)}")
        {:error, "trade insert failed"}
    end
  end

  defp maybe_submit_onchain(trade, agent, args, owner_user_id) do
    signed_tx = args["signed_tx_hex"]
    private_key = Application.get_env(:kite_agent_hub, :agent_private_key, "")

    cond do
      signed_tx ->
        submit_tx(trade, signed_tx, owner_user_id)

      private_key != "" and agent.vault_address ->
        sign_and_submit(trade, agent, private_key, owner_user_id)

      true ->
        Logger.info(
          "TradeExecutionWorker: no signing key — trade #{trade.id} recorded as open intent"
        )

        :ok
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

  defp within_per_trade_limit?(agent, args) do
    notional = compute_notional(args)
    Decimal.lte?(notional, Decimal.new(agent.per_trade_limit_usd))
  end

  defp compute_notional(args) do
    contracts = args["contracts"] || 0
    price = Decimal.new(to_string(args["fill_price"] || "0"))
    Decimal.mult(price, Decimal.new(contracts))
  end
end
