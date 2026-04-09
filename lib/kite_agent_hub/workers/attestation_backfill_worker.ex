defmodule KiteAgentHub.Workers.AttestationBackfillWorker do
  @moduledoc """
  Periodically scans for settled trades that don't yet have an
  `attestation_tx_hash` and enqueues `KiteAttestationWorker` jobs for
  each one. PR #105.

  This exists so that:

    - Trades that settled BEFORE PR #101 (the attestation pipeline)
      shipped get retroactively attested
    - Trades whose attestation jobs were discarded during the
      `AGENT_PRIVATE_KEY` misconfiguration window (~v112-v117) get
      a clean second attempt now that the key is correct
    - Any future transient failure (RPC outage, gas issue) eventually
      reconciles without manual intervention

  ## Idempotency

  `KiteAttestationWorker` already skips if `attestation_tx_hash` is set
  AND uses `unique: [period: 600]` on its own queue, so re-enqueuing
  the same trade is a no-op. This worker just keeps inserting; the
  unique constraint deduplicates downstream.

  ## Bounded scan

  Each tick processes at most `@batch_size` trades. On a busy backlog,
  the queue catches up across multiple ticks rather than blasting
  hundreds of jobs at once. Once the backlog is empty, the scan
  returns zero rows and the tick is a cheap no-op.
  """

  use Oban.Worker,
    queue: :settlement,
    max_attempts: 3,
    unique: [period: 60, fields: [:worker]]

  require Logger

  alias KiteAgentHub.Trading
  alias KiteAgentHub.Workers.KiteAttestationWorker

  @batch_size 50

  @impl Oban.Worker
  def perform(_job) do
    case Trading.list_unattested_settled_trades(@batch_size) do
      [] ->
        :ok

      trades ->
        Logger.info(
          "AttestationBackfillWorker: enqueueing #{length(trades)} unattested settled trade(s)"
        )

        Enum.each(trades, fn trade ->
          %{trade_id: trade.id}
          |> KiteAttestationWorker.new()
          |> Oban.insert()
        end)

        :ok
    end
  end
end
