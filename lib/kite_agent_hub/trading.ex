defmodule KiteAgentHub.Trading do
  import Ecto.Query
  alias KiteAgentHub.{CollectiveIntelligence, Repo}
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

  @doc """
  Profile-only update (name, tags, bio). Cannot change api_token,
  wallet, org, or status — see `KiteAgent.profile_changeset/2`.
  """
  def update_agent_profile(%KiteAgent{} = agent, attrs) do
    case agent
         |> KiteAgent.profile_changeset(attrs)
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        ok

      err ->
        err
    end
  end

  @doc """
  Rotate the agent's api_token to a new server-generated value and
  return the *updated* struct. The caller is responsible for showing
  the plaintext to the user once — we don't retain it anywhere except
  the DB column. Every call to this function invalidates the previous
  token.
  """
  def rotate_agent_api_token(%KiteAgent{} = agent) do
    case agent
         |> KiteAgent.rotate_token_changeset()
         |> Repo.update() do
      {:ok, updated} = ok ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        ok

      err ->
        err
    end
  end

  @doc """
  Archive an agent (soft-delete). The row is retained so audit trail
  stays intact (open trades, attestation history, etc.), but the agent
  is flipped to `archived`, the runner is stopped, and every open
  trade the agent still holds is auto-cancelled via the same path the
  StuckTradeSweeper uses — so broker-side orders also clear, not just
  the DB rows.

  Returns `{:ok, %{agent, cancelled_count}}` on success.
  """
  def archive_agent(%KiteAgent{} = agent) do
    case agent
         |> KiteAgent.archive_changeset()
         |> Repo.update() do
      {:ok, archived} ->
        # Stop the runner before cancelling — prevents it from queueing
        # new trades mid-archive.
        KiteAgentHub.Kite.AgentRunnerSupervisor.stop_agent(archived.id)

        # Move every still-open trade owned by this agent into the
        # cancelled path. cutoff = utc_now guarantees we catch every
        # open row regardless of age.
        {count, _trades} =
          auto_cancel_stuck_trades(
            DateTime.utc_now() |> DateTime.truncate(:second),
            agent_id: archived.id
          )

        Phoenix.PubSub.broadcast(@pubsub, "agent:#{archived.id}", {:agent_updated, archived})

        {:ok, %{agent: archived, cancelled_count: count}}

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

  @doc """
  List trades with a `:display_pnl` value for UI rows.

  Broker-settled Alpaca rows historically stored `realized_pnl = 0`
  as a settlement placeholder. The dashboard aggregate is broker-derived,
  so the trade-history UI needs a row-level realized P&L that does not
  blindly render that placeholder. We compute FIFO P&L for settled sell
  rows from the agent's settled trade fills and keep buys/open rows as
  nil because they have no realized P&L yet.
  """
  def list_trades_with_display_pnl(agent_id, opts \\ []) do
    display_pnl_by_id = display_pnl_by_trade_id(agent_id)

    agent_id
    |> list_trades(opts)
    |> Enum.map(fn trade ->
      Map.put(trade, :display_pnl, Map.get(display_pnl_by_id, trade.id))
    end)
  end

  defp display_pnl_by_trade_id(agent_id) do
    TradeRecord
    |> where([t], t.kite_agent_id == ^agent_id)
    |> where([t], t.status == "settled")
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
    |> Enum.reduce({%{}, %{}}, fn trade, {lots_by_market, pnl_by_id} ->
      key = {trade.platform || "kite", trade.market}

      case trade.action do
        "buy" ->
          lot = {Decimal.new(trade.contracts || 0), trade.fill_price}
          {Map.update(lots_by_market, key, [lot], &(&1 ++ [lot])), pnl_by_id}

        "sell" ->
          lots = Map.get(lots_by_market, key, [])
          qty = Decimal.new(trade.contracts || 0)
          {pnl, remaining_lots} = consume_fifo_lots(lots, qty, trade.fill_price, Decimal.new(0))

          pnl =
            case nonzero_decimal(trade.realized_pnl) do
              nil -> pnl
              stored -> stored
            end

          {
            Map.put(lots_by_market, key, remaining_lots),
            Map.put(pnl_by_id, trade.id, pnl)
          }

        _ ->
          {lots_by_market, pnl_by_id}
      end
    end)
    |> elem(1)
  end

  defp consume_fifo_lots([], _qty_left, _sell_price, acc), do: {acc, []}

  defp consume_fifo_lots([{lot_qty, lot_price} | rest], qty_left, sell_price, acc) do
    if Decimal.compare(qty_left, 0) == :gt do
      qty_used = Decimal.min(lot_qty, qty_left)
      pnl = sell_price |> Decimal.sub(lot_price) |> Decimal.mult(qty_used)
      remaining_qty = Decimal.sub(lot_qty, qty_used)
      remaining_to_close = Decimal.sub(qty_left, qty_used)
      next_acc = Decimal.add(acc, pnl)

      if Decimal.compare(remaining_qty, 0) == :gt do
        {next_acc, [{remaining_qty, lot_price} | rest]}
      else
        consume_fifo_lots(rest, remaining_to_close, sell_price, next_acc)
      end
    else
      {acc, [{lot_qty, lot_price} | rest]}
    end
  end

  defp nonzero_decimal(nil), do: nil

  defp nonzero_decimal(decimal) do
    if Decimal.equal?(decimal, 0), do: nil, else: decimal
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

            _ = CollectiveIntelligence.record_trade_outcome(updated)
            ok

          err ->
            err
        end

      %TradeRecord{} = trade ->
        {:ok, :already_terminal, trade}
    end
  end

  @doc """
  Sweep: flip trades with status=`"open"` older than `cutoff` to
  `"cancelled"`. Returns `{count, trades}` where `trades` is the list of
  rows that were updated (so the caller can enqueue downstream work,
  such as calling Alpaca's cancel endpoint, for each one).

  Pass `agent_id: id` when sweeping on behalf of one agent. RLS still
  applies, but the explicit filter prevents an org-owner sweep from
  cancelling another agent's unrelated open trades.
  """
  def auto_cancel_stuck_trades(cutoff, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    agent_id = Keyword.get(opts, :agent_id)

    stuck_query =
      TradeRecord
      |> where([t], t.status == "open" and t.inserted_at < ^cutoff)
      |> then(fn q -> if agent_id, do: where(q, [t], t.kite_agent_id == ^agent_id), else: q end)

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

          _ = CollectiveIntelligence.record_trade_outcome(trade)
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
        _ = CollectiveIntelligence.record_trade_outcome(trade)
        ok

      err ->
        err
    end
  end

  @doc """
  Generic trade-row update with PubSub broadcast. Every worker that
  mutates a trade outside of `create_trade/1`, `cancel_trade/2`, or
  `settle_trade/2` should route through here so subscribers
  (DashboardLive, TradesLive, agent runners) see the change in real
  time instead of waiting for the next mount.

  Any update that transitions the trade into a terminal status
  (`failed` or `cancelled`) also fires CollectiveIntelligence outcome
  recording, mirroring what cancel_trade/2 + settle_trade/2 already
  do for their specific paths.

  Settles flow through `settle_trade/2` instead — it has a specialized
  changeset (status + realized_pnl only) and already records to KCI.
  """
  def update_trade(%TradeRecord{} = record, attrs) do
    case record |> TradeRecord.changeset(attrs) |> Repo.update() do
      {:ok, updated} = ok ->
        _ = broadcast_trade_updated(record, updated)
        ok

      err ->
        err
    end
  end

  @doc """
  Specialized update for the post-settlement attestation_tx_hash flip.
  Goes through `TradeRecord.attestation_changeset/2` (which locks the
  field on first write) and broadcasts so the dashboard's attestation
  cards refresh as soon as the on-chain receipt lands.
  """
  def set_trade_attestation(%TradeRecord{} = record, tx_hash) when is_binary(tx_hash) do
    case record |> TradeRecord.attestation_changeset(tx_hash) |> Repo.update() do
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
  end

  defp broadcast_trade_updated(prev_record, updated) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "agent:#{updated.kite_agent_id}",
      {:trade_updated, updated}
    )

    if updated.status in ~w(settled failed cancelled) and prev_record.status != updated.status do
      _ = CollectiveIntelligence.record_trade_outcome(updated)
    end

    :ok
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
  Same as `list_recent_attestations/2` but each row carries a
  `:display_pnl` value computed via the same FIFO logic used for the
  trades list. Without this, the dashboard's attestations tab reads
  `realized_pnl` straight off the row — and Alpaca-settled rows store
  `0` there as a placeholder, so every PnL cell renders as $0.0000.
  """
  def list_recent_attestations_with_display_pnl(agent_id, limit \\ 5) do
    display_pnl_by_id = display_pnl_by_trade_id(agent_id)

    agent_id
    |> list_recent_attestations(limit)
    |> Enum.map(fn att ->
      Map.put(att, :display_pnl, Map.get(display_pnl_by_id, att.id))
    end)
  end

  # ── Edge-score snapshots ─────────────────────────────────────────────────────

  alias KiteAgentHub.Kite.EdgeScoreSnapshot

  @doc """
  Insert a single edge-score snapshot row. Called by the cron worker
  for each position returned by `PortfolioEdgeScorer.score_portfolio/1`.
  Idempotent at the time-granularity level: the composite index on
  (organization_id, ticker, inserted_at) keeps lookups fast even as
  rows accumulate.
  """
  def insert_edge_score_snapshot(attrs) do
    %EdgeScoreSnapshot{}
    |> EdgeScoreSnapshot.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Return snapshot rows for the given org, newest first.

  Options:
    - :ticker   — filter to a specific ticker (case-insensitive exact match)
    - :hours    — max age in hours (default 24, capped at 168 / 1 week)
    - :platform — "alpaca" or "kalshi"
    - :limit    — row cap (default 500, max 2000)
  """
  def list_edge_score_history(org_id, opts \\ []) do
    hours = min(Keyword.get(opts, :hours, 24), 168)
    limit = min(Keyword.get(opts, :limit, 500), 2000)
    ticker = Keyword.get(opts, :ticker)
    platform = Keyword.get(opts, :platform)

    cutoff = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second)

    EdgeScoreSnapshot
    |> where([s], s.organization_id == ^org_id)
    |> where([s], s.inserted_at >= ^cutoff)
    |> then(fn q -> if ticker, do: where(q, [s], s.ticker == ^ticker), else: q end)
    |> then(fn q -> if platform, do: where(q, [s], s.platform == ^platform), else: q end)
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns up to `limit` settled trades across ALL agents that do NOT yet
  have an `attestation_tx_hash`. Used by `AttestationBackfillWorker` to
  retroactively attest trades that settled before the attestation
  pipeline existed, or while AGENT_PRIVATE_KEY was misconfigured.

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
