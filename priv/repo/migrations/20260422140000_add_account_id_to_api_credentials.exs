defmodule KiteAgentHub.Repo.Migrations.AddAccountIdToApiCredentials do
  use Ecto.Migration

  def change do
    alter table(:api_credentials) do
      add :account_id, :string
      add :server, :string
    end
  end
end
