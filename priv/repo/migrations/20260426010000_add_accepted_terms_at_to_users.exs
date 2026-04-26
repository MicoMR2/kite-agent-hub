defmodule KiteAgentHub.Repo.Migrations.AddAcceptedTermsAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :accepted_terms_at, :utc_datetime
    end
  end
end
