defmodule KiteAgentHub.Repo.Migrations.AddObanJobs do
  use Ecto.Migration

  def change do
    Oban.Migrations.up(version: 12)
  end
end
