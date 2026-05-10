defmodule KiteAgentHub.Repo.Migrations.CreateInviteSystem do
  use Ecto.Migration

  def change do
    create table(:access_requests) do
      add :name, :string, null: false
      add :email, :string, null: false
      add :notes, :text
      add :status, :string, null: false, default: "pending"
      add :processed_at, :utc_datetime
      add :processed_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:access_requests, [:status, :inserted_at])
    create index(:access_requests, [:email])

    create table(:invite_codes) do
      add :code_hash, :binary, null: false
      add :email, :string
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :used_by_user_id, references(:users, on_delete: :nilify_all)
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :access_request_id, references(:access_requests, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invite_codes, [:code_hash])
    create index(:invite_codes, [:email])
    create index(:invite_codes, [:used_at])
  end
end
