defmodule KiteAgentHub.Repo do
  use Ecto.Repo,
    otp_app: :kite_agent_hub,
    adapter: Ecto.Adapters.Postgres
end
