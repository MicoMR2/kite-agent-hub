defmodule KiteAgentHub.Repo.Migrations.AddWorkosIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :workos_id, :string
      add :first_name, :string
      add :last_name, :string
    end

    create unique_index(:users, [:workos_id])
  end
end
