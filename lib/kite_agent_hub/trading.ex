defmodule KiteAgentHub.Trading do
  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{KiteAgent, TradeRecord}

  @pubsub KiteAgentHub.PubSub

  # ── Agents ────────────────────────────────────────────────────────────────────

  def list_agents(org_id) do
    KiteAgent
    |> where(organization_id: ^org_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(KiteAgent, id)

  def list_all_active_agents do
    KiteAgent
    |> where(status: "active")
    |> Repo.all()
  end

  def get_agent_by_wallet(wallet_address) do
    Repo.get_by(KiteAgent, wallet_address: wallet_address)
  end

  def get_agent_by_token(api_token) when is_binary(api_token) and api_token != "" do
    Repo.get_by(KiteAgent, api_token: api_token)
  end

  def get_agent_by_token(_), do: nil

  def create_agent(attrs) do
    %KiteAgent{}
    |> KiteAgent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent_name(%KiteAgent{} = agent, name) do
    agent
    |> KiteAgent.name_changeset(%{name: name})
    |> Repo.update()
  end

  def update_vault_address(%KiteAgent{} = agent, vault_address) do
    agent
    |> KiteAgent.changeset(%{vault_address: vault_address})
    |> Repo.update()
  end

  def activate_agent(%KiteAgent{} = agent, vault_address) do
    case agent
         |> KiteAgent.changeset(%{vault_address: vault_address, status: "active"})
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        KiteAgentHub.Kite.AgentRunnerSupervisor.start_agent(updated.id)
        ok

      err ->
        err
    end
  end

  def pause_agent(%KiteAgent{} = agent) do
    case agent
         |> KiteAgent.changeset(%{status: "paused"})
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        KiteAgentHub.Kite.AgentRunnerSupervisor.stop_agent(updated.id)
        ok

      err ->
        err
    end
  end

  def resume_agent(%KiteAgent{} = agent) do
    case agent
         |> KiteAgent.changeset(%{status: "active"})
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        KiteAgentHub.Kite.AgentRunnerSupervisor.start_agent(updated.id)
        ok

      err ->
        err
    end
  end

  # ── Trade Records ─────────────────────────────────────────────────────────────

  def list_trades(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)

    TradeRecord
    |> where(kite_agent_id: ^agent_id)
    |> then(fn q -> if status, do: where(q, status: ^status), else: q end)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  def list_open_trades(agent_id) do
    list_trades(agent_id, status: "open", limit: 200)
  end

  @doc """
  List open Alpaca trades for a single agent that have a non-nil
  platform_order_id. Used by AlpacaSettlementWorker which iterates
  agents under their own RLS scope and asks for the subset that needs
  poll-based fill settlement.
  """
  def list_open_alpaca_trades(agent_id) do
    TradeRecord
    |> where([t], t.kite_agent_id == ^agent_id)
    |> where([t], t.status == "open")
    |> where([t], t.platform == "alpaca")
    |> where([t], not is_nil(t.platform_order_id))
    |> order_by(asc: :inserted_at)
    |> limit(200)
    |> Repo.all()
  end

  def get_trade_for_agent(trade_id, agent_id) do
    Repo.get_by(TradeRecord, id: trade_id, kite_agent_id: agent_id)
  end

  def count_open_trades(agent_id) do
    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "open")
    |> Repo.aggregate(:count)
  end

  def create_trade(attrs) do
    case %TradeRecord{}
         |> TradeRecord.changeset(attrs)
         |> Repo.insert() do
      {:ok, trade} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{trade.kite_agent_id}", {:trade_created, trade})
        ok

      err ->
        err
    end
  end

  @doc """
  Cancel a trade the agent owns. Ownership is enforced: the trade
  must belong to `agent_id` or this returns `{:error, :not_found}`
  (we don't leak existence across agents).

  Returns:
    - `{:ok, trade}`                   — flipped from `open` → `cancelled`
    - `{:ok, :already_terminal, trade}` — idempotent: already in a terminal
      state (cancelled / settled / failed); no DB write, caller can treat
      as success
    - `{:error, :not_found}`           — trade does not exist or isn't this
      agent's
    - `{:error, changeset}`            — update failed

  For Alpaca trades with a `platform_order_id`, the caller is responsible
  for forwarding the cancel to Alpaca (see the controller); this function
  only moves the DB row. Keeping the two concerns separate lets the sweep
  worker drive both without duplicating changeset logic.
  """
  def cancel_trade(trade_id, agent_id) do
    case get_trade_for_agent(trade_id, agent_id) do
      nil ->
        {:error, :not_found}

      %TradeRecord{status: "open"} = trade ->
        case trade
             |> TradeRecord.changeset(%{status: "cancelled"})
             |> Repo.update() do
          {:ok, updated} = ok ->
            Phoenix.PubSub.broadcast(
              @pubsub,
              "agent:#{updated.kite_agent_id}",
              {:trade_updated, updated}
            )

            ok

          err ->
            err
        end

      %TradeRecord{} = trade ->
        {:ok, :already_terminal, trade}
    end
  end

  @doc """
  Sweep: flip any trade with status=`"open"` older than `cutoff` to
  `"cancelled"`. Returns `{count, trades}` where `trades` is the list of
  rows that were updated (so the caller can enqueue downstream work —
  e.g. calling Alpaca's cancel endpoint — for each one). Scoped to the
  caller's RLS context; the sweep worker re-establishes per-agent scope
  before calling this.
  """
  def auto_cancel_stuck_trades(cutoff) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    stuck_query =
      TradeRecord
      |> where([t], t.status == "open" and t.inserted_at < ^cutoff)

    # Load first so we can broadcast + hand the structs back to the
    # caller (the sweep worker uses them to forward cancels to the
    # broker). The set stays small because the worker runs every
    # minute — unbounded growth isn't a realistic concern.
    trades = Repo.all(stuck_query)

    case trades do
      [] ->
        {0, []}

      rows ->
        ids = Enum.map(rows, & &1.id)

        {count, _} =
          TradeRecord
          |> where([t], t.id in ^ids)
          |> Repo.update_all(set: [status: "cancelled", updated_at: now])

        updated = Enum.map(rows, &%{&1 | status: "cancelled", updated_at: now})

        Enum.each(updated, fn trade ->
          Phoenix.PubSub.broadcast(
            @pubsub,
            "agent:#{trade.kite_agent_id}",
            {:trade_updated, trade}
          )
        end)

        {count, updated}
    end
  end

  def settle_trade(%TradeRecord{} = record, pnl) do
    case record
         |> TradeRecord.settle_changeset(pnl)
         |> Repo.update() do
      {:ok, trade} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{trade.kite_agent_id}", {:trade_updated, trade})
        ok

      err ->
        err
    end
  end

  def total_pnl(agent_id) do
    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "settled")
    |> Repo.aggregate(:sum, :realized_pnl) || Decimal.new(0)
  end

  @doc """
  Returns aggregated P&L stats for an agent:
  %{total_pnl, win_count, loss_count, open_count, trade_count}
  """
  def agent_pnl_stats(agent_id) do
    settled =
      TradeRecord
      |> where(kite_agent_id: ^agent_id, status: "settled")
      |> select([t], %{
        total_pnl: sum(t.realized_pnl),
        win_count: sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        loss_count: sum(fragment("CASE WHEN ? < 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        trade_count: count(t.id)
      })
      |> Repo.one()

    open_count =
      TradeRecord
      |> where(kite_agent_id: ^agent_id, status: "open")
      |> Repo.aggregate(:count)

    %{
      total_pnl: settled.total_pnl || Decimal.new(0),
      win_count: settled.win_count || 0,
      loss_count: settled.loss_count || 0,
      trade_count: settled.trade_count || 0,
      open_count: open_count
    }
  end

  @doc """
  Count of trades for the given agent that have been attested on Kite chain
  (i.e. `attestation_tx_hash` is set). Used by the dashboard's on-chain
  activity summary card. PR #103.
  """
  def count_attestations(agent_id) do
    TradeRecord
    |> where([t], t.kite_agent_id == ^agent_id and not is_nil(t.attestation_tx_hash))
    |> Repo.aggregate(:count)
  end

  @doc """
  Most recent N attested trades for an agent, newest first. Used by the
  dashboard's on-chain activity summary so judges can click straight
  through to the latest receipts on testnet.kitescan.ai. PR #103.
  """
  def list_recent_attestations(agent_id, limit \\ 5) do
    TradeRecord
    |> where([t], t.kite_agent_id == ^agent_id and not is_nil(t.attestation_tx_hash))
    |> order_by([t], desc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns up to `limit` settled trades across ALL agents that do NOT yet
  have an `attestation_tx_hash`. Used by `AttestationBackfillWorker` to
  retroactively attest trades that settled before the attestation
  pipeline existed (or while AGENT_PRIVATE_KEY was misconfigured).

  Bounded scan keeps each backfill tick small. The worker calls this
  on a schedule and enqueues KiteAttestationWorker for each result; the
  attestation worker is idempotent so re-runs are safe. PR #105.
  """
  def list_unattested_settled_trades(limit \\ 50) do
    TradeRecord
    |> where([t], t.status == "settled" and is_nil(t.attestation_tx_hash))
    |> order_by([t], asc: t.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
