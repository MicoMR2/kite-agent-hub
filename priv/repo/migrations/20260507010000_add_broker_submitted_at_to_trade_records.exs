defmodule KiteAgentHub.Repo.Migrations.AddBrokerSubmittedAtToTradeRecords do
  use Ecto.Migration

  # Marker timestamp set in Phase 3 of the live trade-execution path
  # *atomically* with `platform_order_id`. Lets the StuckTradeSweeper
  # distinguish two orphan shapes:
  #
  #   * row in `:pending` with `broker_submitted_at = NULL`
  #     → never reached the broker (Phase 2 timeout); safe to fail
  #   * row in `:pending` with `broker_submitted_at != NULL`
  #     → broker has the order but our Phase 3 DB write didn't land;
  #       reconciler must verify with broker before failing the row
  #
  # Backfilled to NULL for existing rows — they all predate the
  # pending-row pattern, are already in terminal states, and never
  # need to be reconciled against the broker.
  def change do
    alter table(:trade_records) do
      add :broker_submitted_at, :utc_datetime_usec, null: true
    end
  end
end
