defmodule KiteAgentHub.Repo.Migrations.AddAttestationTxHashToTradeRecords do
  use Ecto.Migration

  def change do
    alter table(:trade_records) do
      # Hex-encoded tx hash from the Kite chain attestation submitted by
      # KiteAttestationWorker after a trade settles. Null until attested,
      # set exactly once. PR #101 — settlement attestation pipeline.
      add :attestation_tx_hash, :string
    end

    create index(:trade_records, [:attestation_tx_hash],
             where: "attestation_tx_hash IS NOT NULL"
           )
  end
end
