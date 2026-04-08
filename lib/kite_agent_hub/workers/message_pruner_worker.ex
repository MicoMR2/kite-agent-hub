defmodule KiteAgentHub.Workers.MessagePrunerWorker do
  @moduledoc """
  Oban worker that prunes stale chat messages per org. Implements Mico's
  data minimization direction: messages are working memory for agents,
  not a long-term data store.

  ## Retention rules

  Per organization:

    1. Delete any message older than 24 hours, UNLESS doing so would
       leave fewer than 100 messages in that org.
    2. Keep at least the most recent 100 messages per org so agents
       reconnecting after a brief outage still have usable context.

  This means active orgs will carry roughly 100–several-hundred messages
  at any given time, and inactive orgs are trimmed to exactly 100 after
  the first prune that catches them.

  ## Schedule

  Runs every 6 hours via Oban cron (see `config/config.exs`). No args —
  the worker handles all orgs in a single pass.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query
  require Logger

  alias KiteAgentHub.Repo
  alias KiteAgentHub.Chat.ChatMessage

  @keep_at_least 100
  @max_age_hours 24

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@max_age_hours * 3600, :second)
      |> DateTime.truncate(:second)

    org_ids =
      ChatMessage
      |> distinct(true)
      |> select([m], m.organization_id)
      |> Repo.all()

    totals =
      Enum.reduce(org_ids, %{scanned: 0, deleted: 0}, fn org_id, acc ->
        deleted = prune_org(org_id, cutoff)
        %{acc | scanned: acc.scanned + 1, deleted: acc.deleted + deleted}
      end)

    Logger.info(
      "MessagePrunerWorker: scanned #{totals.scanned} orgs, deleted #{totals.deleted} messages older than #{@max_age_hours}h (keep last #{@keep_at_least} per org)"
    )

    :ok
  end

  # For each org: find the message that sits at position @keep_at_least
  # (newest-first), and delete everything older than both that anchor AND
  # the age cutoff. This guarantees we never drop below @keep_at_least and
  # never keep a message older than the cutoff unless it's in the last 100.
  defp prune_org(org_id, cutoff) do
    anchor_ts =
      ChatMessage
      |> where([m], m.organization_id == ^org_id)
      |> order_by([m], desc: m.inserted_at)
      |> offset(^@keep_at_least)
      |> limit(1)
      |> select([m], m.inserted_at)
      |> Repo.one()

    case anchor_ts do
      nil ->
        # Fewer than @keep_at_least messages — keep everything.
        0

      ts ->
        # Delete messages older than BOTH the anchor (so we preserve
        # exactly @keep_at_least recent ones) AND the cutoff (so we
        # never delete anything that's still within the TTL window).
        {count, _} =
          ChatMessage
          |> where([m], m.organization_id == ^org_id)
          |> where([m], m.inserted_at < ^ts)
          |> where([m], m.inserted_at < ^cutoff)
          |> Repo.delete_all()

        count
    end
  end
end
