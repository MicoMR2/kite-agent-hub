defmodule KiteAgentHub.Repo.Migrations.AlterTradeRecordsReasonToText do
  use Ecto.Migration

  def change do
    alter table(:trade_records) do
      modify :reason, :text
    end
  end
end
