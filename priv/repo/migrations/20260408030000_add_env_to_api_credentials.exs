defmodule KiteAgentHub.Repo.Migrations.AddEnvToApiCredentials do
  use Ecto.Migration

  @moduledoc """
  Adds a single `env` column to `api_credentials` so a user can
  store separate paper/demo and live keys per provider and the
  platform clients route to the correct base URL.

  Values:
    - "paper" for Alpaca paper trading / Kalshi demo (default, safe)
    - "live"  for Alpaca live / Kalshi production

  We default to "paper" so existing rows stay on the safe sandbox
  URL. The constraint is enforced at the schema changeset level
  rather than the DB to keep migrations reversible.
  """

  def change do
    alter table(:api_credentials) do
      add :env, :string, null: false, default: "paper"
    end
  end
end
