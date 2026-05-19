defmodule KiteAgentHub.Repo.Migrations.AddClientOrderIdToTradeRecords do
  use Ecto.Migration

  # Idempotency key for Kalshi (and future broker) order submissions.
  # Generated KAH-side at trade-row insert, persisted BEFORE the broker
  # POST goes out so a Req.TransportError timeout never loses the order
  # ID (PR-B write-ordering fix). Unique-where-set so legacy zombies
  # (NULL client_order_id) don't conflict with the index.
  def change do
    alter table(:trade_records) do
      add :client_order_id, :string
    end

    create unique_index(
             :trade_records,
             [:client_order_id],
             where: "client_order_id IS NOT NULL",
             name: :trade_records_client_order_id_index
           )
  end
end
