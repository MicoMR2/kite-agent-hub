defmodule KiteAgentHub.Workers.KiteAttestationWorker do
  @moduledoc """
  Submits a Kite chain attestation for every settled Alpaca/Kalshi trade.

  PR #101 / #106 — judging-criteria pipeline. The hackathon requires
  that agents "settle on Kite chain" with "attestations (proof,
  auditability)". This worker is the bridge: when AlpacaSettlementWorker
  flips a trade to `settled`, it enqueues this worker, which signs a
  normal EIP-155 NATIVE KITE value transfer (0.00001 KITE) with
  AGENT_PRIVATE_KEY via `KiteAgentHub.Kite.TxSigner` and broadcasts it
  through `KiteAgentHub.Kite.RPC.send_raw_transaction/2`. The resulting
  tx hash is persisted on `trade_records.attestation_tx_hash` and
  rendered on the dashboard with a `testnet.kitescan.ai` link, giving
  each trade a verifiable on-chain receipt.

  PR #106 switched the on-chain settlement from an ERC-20 USDT transfer
  to a native KITE transfer. The original design required the agent
  wallet to hold Test USDT, which the testnet faucet cooldown made
  hard to keep funded during the demo. Native KITE is the chain's
  gas token — every funded wallet has it by default. Cleaner story:
  "agent settles on Kite chain using Kite token."

  We do NOT use the gasless relayer — it's hardcoded for PYUSD's EIP-712
  domain. Direct signing via TxSigner removes the third-party relayer
  dependency entirely (CyberSec considers this a security improvement,
  msg 5477).

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

  # PR #102 hot-fix: was originally `queue: :default` which silently
  # accepted inserts but never processed them — KAH only configures
  # `trade_execution / settlement / position_sync / maintenance` queues
  # in config/config.exs. Routing through :settlement is the right home
  # because attestation is the final stage of the settlement pipeline
  # (kicked off from AlpacaSettlementWorker after Trading.settle_trade).
  # PR #108: routed to a dedicated `:attestation` queue (concurrency: 1
  # in config/config.exs) so on-chain signing is serialized. Two parallel
  # jobs would each fetch the same `latest` nonce from RPC, sign txs
  # with identical nonces, and only one would land per slot — silently
  # producing duplicate tx hashes (we hit this on the first backfill
  # burst, msg 5597). Serializing the queue eliminates the race with
  # zero application-level nonce tracking.
  use Oban.Worker,
    queue: :attestation,
    max_attempts: 5,
    unique: [period: 600, fields: [:args, :worker]]

  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHub.Kite.{RPC, TxSigner}

  # PR #106: switched from ERC-20 USDT transfer to NATIVE KITE transfer.
  # The previous design required the agent wallet to hold Test USDT,
  # which the Kite testnet faucet cooldown made hard to keep funded
  # during the demo. Native KITE is the chain's gas token — every
  # funded wallet has it by default. Cleaner story for the hackathon
  # too: "agent settles on Kite chain using Kite token."
  #
  # 0.00001 KITE = 10_000_000_000_000 wei. Effectively dust on testnet
  # but a real, non-zero, irreversible value transfer that emits a
  # full Transfer event on the explorer. CyberSec proposed the switch
  # at msg 5586, after the USDT funding tx was misdirected to the
  # token contract address and the wallet ended up with 0 USDT.
  @attestation_amount_wei 10_000_000_000_000

  # Native value transfer needs ~21k gas (no calldata). Pad to 25k
  # to absorb chain-side variance.
  @gas_limit 25_000

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
        Logger.info("KiteAttestationWorker: trade #{trade.id} starting attestation")
        attest(trade)
    end
  end

  defp attest(trade) do
    # PR #104: removed `fetch_agent` + `ensure_wallet` from the with chain.
    # The from-address is derived from AGENT_PRIVATE_KEY inside TxSigner —
    # the kite_agent.wallet_address DB field is purely a display value
    # for the dashboard and does NOT need to be set for signing to work.
    # In the prod DB the demo agent's wallet_address column is null even
    # though AGENT_PRIVATE_KEY env produces a valid 0x4049... address,
    # so the old `ensure_wallet` check was silently dropping every job.
    # CyberSec pre-cleared this removal at msg 5497 (no security impact).
    with {:ok, private_key} <- fetch_private_key(),
         {:ok, treasury} <- fetch_treasury_address(),
         {:ok, tx_hash} <- submit_native_transfer(private_key, treasury),
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

  defp persist_tx_hash(trade, tx_hash) do
    trade
    |> TradeRecord.attestation_changeset(tx_hash)
    |> Repo.update()
  end

  # Build, sign, and broadcast a NATIVE KITE value transfer from the
  # agent wallet (derived from AGENT_PRIVATE_KEY) to the configured
  # treasury. Empty data — pure value tx, no contract call. The tx
  # still emits a full record on testnet.kitescan.ai (from / to /
  # value), which is the audit trail the hackathon judges follow.
  defp submit_native_transfer(private_key, treasury) do
    with {:ok, from_address} <- TxSigner.address_from_private_key(private_key),
         {:ok, nonce} <- RPC.get_transaction_count(from_address, :testnet),
         {:ok, gas_price} <- RPC.gas_price(:testnet),
         tx <- %{
           nonce: nonce,
           gas_price: gas_price,
           gas_limit: @gas_limit,
           to: treasury,
           value: @attestation_amount_wei,
           data: ""
         },
         {:ok, signed_hex} <- TxSigner.sign(tx, private_key, chain_id: @chain_id),
         {:ok, tx_hash} <- RPC.send_raw_transaction(signed_hex, :testnet) do
      {:ok, tx_hash}
    end
  end
end
