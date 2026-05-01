defmodule KiteAgentHub.Repo.Migrations.AlterTradeRecordsContractsToNumeric do
  use Ecto.Migration

  # Postgres allows widening integer → numeric without a USING cast and
  # without rewriting the table. Existing whole-number rows are
  # preserved; the new type lets us store fractional contract sizes
  # (e.g. 0.001 BTC, 0.0042 ETH) which the old :integer field silently
  # truncated to 0 — failing validate_number(greater_than: 0) and
  # producing the "API returns 202 but no trade row" symptom logged in
  # feedback_kah_crypto_whole_units.
  def up do
    alter table(:trade_records) do
      modify :contracts, :numeric, from: :integer
    end
  end

  def down do
    alter table(:trade_records) do
      # Truncate any fractional rows on rollback. There's no clean way
      # back from numeric → integer without a USING cast.
      modify :contracts, :integer,
        from: :numeric,
        using: "trunc(contracts)::integer"
    end
  end
end
