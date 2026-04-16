defmodule KiteAgentHub.Repo.Migrations.AddTagsBioToKiteAgents do
  use Ecto.Migration

  def change do
    alter table(:kite_agents) do
      add :tags, {:array, :string}, null: false, default: []
      add :bio, :text
    end
  end
end
