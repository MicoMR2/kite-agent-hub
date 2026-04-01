defmodule KiteAgentHub.Repo.Migrations.AddPlatformToTradeRecords do
  use Ecto.Migration

  def change do
    alter table(:trade_records) do
      add :platform, :string, default: "kite", null: false
      add :platform_order_id, :string
    end

    create index(:trade_records, [:platform])
  end
end
