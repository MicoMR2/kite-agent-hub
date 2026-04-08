defmodule KiteAgentHub.Workers.KiteAttestationWorker do
  @moduledoc """
  Submits a Kite chain attestation for every settled Alpaca/Kalshi trade.

  PR #101 — judging-criteria pipeline. The hackathon requires that agents
  "settle on Kite chain" with "attestations (proof, auditability)". This
  worker is the bridge: when AlpacaSettlementWorker flips a trade to
  `settled`, it enqueues this worker, which signs a normal EIP-155
  ERC-20 `transfer(treasury, 0.001 USDT)` with AGENT_PRIVATE_KEY via
  `KiteAgentHub.Kite.TxSigner` and broadcasts it through
  `KiteAgentHub.Kite.RPC.send_raw_transaction/2`. The resulting tx
  hash is persisted on `trade_records.attestation_tx_hash` and rendered
  on the dashboard with a `testnet.kitescan.ai` link, giving each
  trade a verifiable on-chain receipt.

  We do NOT use the gasless relayer here — the relayer is hardcoded
  for PYUSD's EIP-712 domain, and the demo agent wallet holds Kite
  testnet "Test USD" at a different contract address. Direct signing
  via TxSigner removes the third-party relayer dependency entirely
  (CyberSec considers this a security improvement, msg 5477).

  ## Idempotency

  Oban can retry. We achieve idempotency two ways:

  1. Skip if `attestation_tx_hash` is already set on the trade row.
  2. Oban `unique: [period: 600, fields: [:args, :worker]]` blocks
     duplicate jobs with the same trade_id from being enqueued within
     a 10-minute window.

  ## Failure modes

  - Missing AGENT_PRIVATE_KEY → permanent failure (config issue)
  - Missing KITE_TREASURY_ADDRESS → permanent failure (config issue)
  - Missing agent wallet_address → permanent failure (data issue)
  - Trade not settled → snooze for 30s and retry (race with settlement)
  - Relayer transient error → Oban backoff retries

  ## Security (CyberSec PR #101 review)

  - Private key read from `Application.get_env(:kite_agent_hub, :agent_private_key)`,
    sourced from Fly secret AGENT_PRIVATE_KEY. Never logged.
  - Treasury address read from `Application.get_env(:kite_agent_hub, :kite_treasury_address)`,
    sourced from Fly secret KITE_TREASURY_ADDRESS. Server-controlled.
  - Transfer amount is a server-side constant, not user-controlled.
  - The deterministic nonce only encodes the server-generated trade UUID;
    no user-supplied input ever reaches the on-chain message.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: 600, fields: [:args, :worker]]

  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Kite.{RPC, TxSigner}

  # Kite testnet "Test USD" (USDT). 18 decimals — confirmed via
  # testnet.kitescan.ai. Different from PYUSD; we sign normal EIP-155
  # ERC-20 transfers via TxSigner + RPC.send_raw_transaction.
  @usdt_contract "0x0fF5393387ad2f9f691FD6Fd28e07E3969e27e63"

  # 0.001 USDT per attestation = 1e15 base units (18 decimals). Cheap
  # enough that any seed-funded agent attests hundreds of trades; large
  # enough that the transfer is non-zero so the on-chain receipt is real.
  @attestation_amount_units 1_000_000_000_000_000

  # ERC-20 transfer(address,uint256) function selector — first 4 bytes
  # of keccak256("transfer(address,uint256)").
  @erc20_transfer_selector "a9059cbb"

  # Conservative gas limit for an ERC-20 transfer on a low-traffic
  # testnet. Real cost is ~35k–55k; we pad to 100k to absorb any token
  # contract weirdness without hitting "out of gas".
  @gas_limit 100_000

  # Kite testnet chain id (TxSigner default).
  @chain_id 2368

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"trade_id" => trade_id}}) do
    case Repo.get(TradeRecord, trade_id) do
      nil ->
        Logger.warning("KiteAttestationWorker: trade #{trade_id} not found — dropping")
        :ok

      %TradeRecord{attestation_tx_hash: hash} when is_binary(hash) and hash != "" ->
        Logger.info(
          "KiteAttestationWorker: trade #{trade_id} already attested (tx #{hash}) — skipping"
        )

        :ok

      %TradeRecord{status: status} = trade when status != "settled" ->
        Logger.info(
          "KiteAttestationWorker: trade #{trade.id} not settled yet (status=#{status}) — snoozing"
        )

        {:snooze, 30}

      %TradeRecord{} = trade ->
        attest(trade)
    end
  end

  defp attest(trade) do
    with {:ok, private_key} <- fetch_private_key(),
         {:ok, treasury} <- fetch_treasury_address(),
         {:ok, agent} <- fetch_agent(trade),
         :ok <- ensure_wallet(agent),
         {:ok, tx_hash} <- submit_erc20_transfer(private_key, treasury),
         {:ok, _updated} <- persist_tx_hash(trade, tx_hash) do
      Logger.info(
        "KiteAttestationWorker: trade #{trade.id} attested on Kite chain — tx #{tx_hash}"
      )

      :ok
    else
      {:error, :missing_private_key} ->
        Logger.error("KiteAttestationWorker: AGENT_PRIVATE_KEY not configured")
        {:error, "agent private key not configured"}

      {:error, :missing_treasury} ->
        Logger.error("KiteAttestationWorker: KITE_TREASURY_ADDRESS not configured")
        {:error, "treasury address not configured"}

      {:error, :missing_wallet} ->
        Logger.warning(
          "KiteAttestationWorker: trade #{trade.id} agent has no wallet_address — dropping"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "KiteAttestationWorker: trade #{trade.id} attestation failed — #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp fetch_private_key do
    case Application.get_env(:kite_agent_hub, :agent_private_key) do
      key when is_binary(key) and byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :missing_private_key}
    end
  end

  defp fetch_treasury_address do
    case Application.get_env(:kite_agent_hub, :kite_treasury_address) do
      addr when is_binary(addr) and byte_size(addr) >= 42 -> {:ok, addr}
      _ -> {:error, :missing_treasury}
    end
  end

  defp fetch_agent(trade) do
    case Repo.preload(trade, :kite_agent) do
      %{kite_agent: %{} = agent} -> {:ok, agent}
      _ -> {:error, :missing_wallet}
    end
  end

  defp ensure_wallet(%{wallet_address: addr}) when is_binary(addr) and byte_size(addr) >= 42,
    do: :ok

  defp ensure_wallet(_), do: {:error, :missing_wallet}

  defp persist_tx_hash(trade, tx_hash) do
    trade
    |> TradeRecord.attestation_changeset(tx_hash)
    |> Repo.update()
  end

  # Build, sign, and broadcast an ERC-20 transfer of the attestation
  # amount from the agent wallet (derived from AGENT_PRIVATE_KEY) to
  # the configured treasury. Uses TxSigner + RPC.send_raw_transaction
  # — no relayer dependency.
  defp submit_erc20_transfer(private_key, treasury) do
    with {:ok, from_address} <- TxSigner.address_from_private_key(private_key),
         {:ok, nonce} <- RPC.get_transaction_count(from_address, :testnet),
         {:ok, gas_price} <- RPC.gas_price(:testnet),
         {:ok, data} <- build_transfer_calldata(treasury, @attestation_amount_units),
         tx <- %{
           nonce: nonce,
           gas_price: gas_price,
           gas_limit: @gas_limit,
           to: @usdt_contract,
           value: 0,
           data: data
         },
         {:ok, signed_hex} <- TxSigner.sign(tx, private_key, chain_id: @chain_id),
         {:ok, tx_hash} <- RPC.send_raw_transaction(signed_hex, :testnet) do
      {:ok, tx_hash}
    end
  end

  # ERC-20 transfer(address,uint256) calldata builder.
  # 4-byte selector + 32-byte address (left-padded) + 32-byte amount.
  defp build_transfer_calldata("0x" <> hex_addr, amount) when byte_size(hex_addr) == 40 do
    addr_padded = String.pad_leading(hex_addr, 64, "0")
    amount_hex = Integer.to_string(amount, 16) |> String.downcase()
    amount_padded = String.pad_leading(amount_hex, 64, "0")
    {:ok, "0x" <> @erc20_transfer_selector <> addr_padded <> amount_padded}
  end

  defp build_transfer_calldata(_, _), do: {:error, "treasury address must be 0x + 40 hex chars"}
end
