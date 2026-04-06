defmodule KiteAgentHub.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :text, :text, null: false
      add :sender_type, :string, null: false  # "user" or "agent"
      add :sender_name, :string, null: false
      add :organization_id, references(:organizations, type: :binary_id, on_delete: :delete_all), null: false
      add :kite_agent_id, references(:kite_agents, type: :binary_id, on_delete: :nilify_all)
      add :user_id, references(:users, type: :bigint, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:chat_messages, [:organization_id, :inserted_at])
  end
end
