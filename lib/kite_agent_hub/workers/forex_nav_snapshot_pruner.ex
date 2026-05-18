defmodule KiteAgentHub.Workers.ForexNavSnapshotPruner do
  @moduledoc """
  Daily retention sweep for `forex_nav_snapshots`. The Session NAV
  history written by `KiteAgentHub.Forex.NavHistory` accumulates at
  ~1 row / 30s / agent (~2880/day/agent); without a sweep it would
  grow unboundedly even though only the last 24h × 30s = 288 samples
  are actually displayed in the sparkline.

  This worker deletes rows older than `@max_age_days`. Conservative
  default (30 days) keeps enough history for "open the agent's
  Session NAV chart and see the last few weeks" — Mico's "ever since
  it has been running" framing from msg 14101.

  Scheduled via `Oban.Plugins.Cron` at 06:00 UTC daily — after-hours
  for both US sessions, off the FX/Asia peak.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  require Logger

  import Ecto.Query, only: [from: 2]

  alias KiteAgentHub.Forex.NavSnapshot
  alias KiteAgentHub.Repo

  @max_age_days 30

  @impl Oban.Worker
  def perform(_job) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@max_age_days, :day)
      |> DateTime.truncate(:second)

    {deleted, _} =
      from(s in NavSnapshot, where: s.inserted_at < ^cutoff)
      |> Repo.delete_all()

    Logger.info(
      "ForexNavSnapshotPruner: deleted #{deleted} samples older than #{@max_age_days} days (cutoff=#{DateTime.to_iso8601(cutoff)})"
    )

    :ok
  end

  @doc false
  def max_age_days, do: @max_age_days
end
