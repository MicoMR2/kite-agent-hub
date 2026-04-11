defmodule KiteAgentHub.Repo.Migrations.NullDuplicateAttestationHashes do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE trade_records
    SET attestation_tx_hash = NULL
    WHERE attestation_tx_hash IN (
      SELECT attestation_tx_hash
      FROM trade_records
      WHERE attestation_tx_hash IS NOT NULL
      GROUP BY attestation_tx_hash
      HAVING COUNT(*) > 1
    );
    """)
  end

  def down do
    :ok
  end
end
