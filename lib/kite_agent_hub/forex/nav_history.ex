defmodule KiteAgentHub.Forex.NavHistory do
  @moduledoc """
  Persistent backing for the Forex tab Session NAV sparkline. Lets the
  in-memory ring buffer (`DashboardLive.@forex_nav_history`) survive
  tab reopens and process restarts.

  Two responsibilities:
    * `record_sample/3` — fire-and-forget insert of `{ts, nav}` for an
      agent. Called from the LV's `append_forex_nav_sample/2` every
      ~30s; failures here MUST NOT block the LV refresh, so callers
      should wrap in a `Task.Supervisor.start_child/2`.
    * `recent_for_agent/2` — load the most recent N samples for an
      agent. Used to seed the in-memory buffer on Forex-tab mount so
      the sparkline opens with history instead of a single dot.

  All queries scope by `kite_agent_id` to prevent cross-agent reads.
  """

  import Ecto.Query, only: [from: 2]

  alias KiteAgentHub.Forex.NavSnapshot
  alias KiteAgentHub.Repo

  @default_limit 288

  @doc """
  Insert one `{ts, nav}` sample for the given agent. Idempotency is
  NOT enforced — duplicate inserts within the same second produce two
  rows. That is acceptable because the ring buffer dedupes display
  anyway and retention will sweep older rows.

  Returns `{:ok, snap}` on success, `{:error, changeset}` on validation
  failure. Caller is expected to handle/log; this function does not
  raise.
  """
  @spec record_sample(binary(), integer(), float()) ::
          {:ok, NavSnapshot.t()} | {:error, Ecto.Changeset.t()}
  def record_sample(agent_id, ts, nav)
      when is_binary(agent_id) and is_integer(ts) and is_float(nav) do
    %NavSnapshot{}
    |> NavSnapshot.changeset(%{kite_agent_id: agent_id, ts: ts, nav: nav})
    |> Repo.insert()
  end

  @doc """
  Return the most recent N samples for an agent as a list of
  `{ts, nav}` tuples, ordered NEWEST-FIRST to match the in-memory
  ring buffer shape consumed by `DashboardLive.session_nav_chart_data/3`.

  ## Options
    * `:limit` — max rows (default 288, matching the ring buffer cap)
  """
  @spec recent_for_agent(binary(), keyword()) :: [{integer(), float()}]
  def recent_for_agent(agent_id, opts \\ []) when is_binary(agent_id) do
    limit = Keyword.get(opts, :limit, @default_limit)

    from(s in NavSnapshot,
      where: s.kite_agent_id == ^agent_id,
      order_by: [desc: s.ts],
      limit: ^limit,
      select: {s.ts, s.nav}
    )
    |> Repo.all()
  end
end
