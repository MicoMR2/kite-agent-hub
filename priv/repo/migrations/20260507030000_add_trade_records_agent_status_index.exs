defmodule KiteAgentHub.Repo.Migrations.AddTradeRecordsAgentStatusIndex do
  use Ecto.Migration

  # Composite index for the four hot per-tick queries shaped
  # `WHERE kite_agent_id = $1 AND status = $2` issued from
  # `Trading.agent_pnl_stats/1` (2 queries) + `Trading.list_open_trades/1`
  # + `Trading.count_open_trades/1`. The original migration created
  # single-column indexes on `:kite_agent_id` and `:status` separately,
  # so each tick query degraded into either a bitmap merge of two
  # index scans or a single-column scan with an in-memory filter.
  # Under N-agent tick collision the queries piled up on the pool —
  # the residual leak observed after every other lift-out fix landed
  # tonight (PRs #300-#308).
  #
  # `CONCURRENTLY` so prod traffic is not blocked while the index
  # builds — no table lock, only a SHARE UPDATE EXCLUSIVE lock.
  # Ecto requires `@disable_ddl_transaction` + `@disable_migration_lock`
  # for `CONCURRENTLY` to work, since CONCURRENTLY cannot run inside
  # a transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(
                           :trade_records,
                           [:kite_agent_id, :status],
                           concurrently: true
                         )
  end
end
