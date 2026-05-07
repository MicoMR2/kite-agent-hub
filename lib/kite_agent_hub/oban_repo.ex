defmodule KiteAgentHub.ObanRepo do
  @moduledoc """
  Dedicated Ecto repository for Oban — its own connection pool,
  isolated from the main `KiteAgentHub.Repo`. Same DATABASE_URL,
  same Postgres database; only the connection-pool fan-in changes.

  Why this exists
  ---------------
  Telemetry trace from `KiteAgentHub.Diagnostics.SlowQueryLogger`
  caught a 30-second `pg_notify` queue wait on the shared pool
  (DevOps msg 8283). Oban uses LISTEN/NOTIFY for cross-node job
  coordination; under burst load those notify calls competed with
  every Trading.* / LiveView / API query and produced the recurring
  `DBConnection.ConnectionError` cascade we'd been chasing all
  night. Giving Oban its own pool removes the contention.

  Operational notes
  -----------------
  * NOT in `:ecto_repos` — `mix ecto.migrate` only runs against the
    main Repo. Oban's own tables are owned by the main Repo's
    migrations (created at boot via `Oban.Migration`).
  * No `Repo.with_user/2` analog needed — Oban does not interact
    with `app.current_user_id`; its internal queries hit
    `oban_jobs`, `oban_peers`, etc. which have no app-level RLS.
  * Pool size is bounded (default 10) — Oban's needs are fixed
    (the Stager + Notifier + per-queue pluck workers); never let
    it grow unbounded.
  """

  use Ecto.Repo,
    otp_app: :kite_agent_hub,
    adapter: Ecto.Adapters.Postgres
end
