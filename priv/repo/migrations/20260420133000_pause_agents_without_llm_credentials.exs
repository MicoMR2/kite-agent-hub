defmodule KiteAgentHub.Repo.Migrations.PauseAgentsWithoutLlmCredentials do
  use Ecto.Migration
  import Ecto.Query, only: [from: 2]

  require Logger

  def up do
    # Active trading agents on orgs that have no LLM credentials
    # (anthropic or openai) would silently break the moment the
    # shared ANTHROPIC_API_KEY is unset. Flip them to "paused" so
    # the operator sees the banner and can add a key to reactivate.
    #
    # Reversible at the row level: the agent can be re-activated
    # from the admin UI once the org has an LLM key configured.
    # `down/0` below does NOT auto-reactivate because we can't know
    # which agents were paused by this migration vs. by a human.
    {count, _} =
      KiteAgentHub.Repo.update_all(
        from(a in "kite_agents",
          where:
            a.agent_type == "trading" and
              a.status == "active" and
              a.organization_id not in subquery(
                from(c in "api_credentials",
                  where: c.provider in ["anthropic", "openai"],
                  select: c.org_id
                )
              )
        ),
        set: [status: "paused", updated_at: DateTime.utc_now()]
      )

    Logger.info(
      "PauseAgentsWithoutLlmCredentials: paused #{count} trading agents on orgs without anthropic/openai credentials"
    )
  end

  def down do
    Logger.info(
      "PauseAgentsWithoutLlmCredentials: no-op on down — agents paused by this migration must be reactivated manually once LLM credentials are configured"
    )
  end
end
