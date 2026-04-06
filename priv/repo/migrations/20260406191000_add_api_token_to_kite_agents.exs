defmodule KiteAgentHub.Repo.Migrations.AddApiTokenToKiteAgents do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", ""

    alter table(:kite_agents) do
      add :api_token, :string
    end

    create unique_index(:kite_agents, [:api_token])

    # Backfill existing agents with random tokens
    execute """
    UPDATE kite_agents SET api_token = 'kite_' || encode(gen_random_bytes(24), 'hex')
    WHERE api_token IS NULL
    """, ""
  end
end
