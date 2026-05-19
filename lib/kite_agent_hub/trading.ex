defmodule KiteAgentHub.Trading do
  import Ecto.Query
  alias Ecto.Multi
  alias KiteAgentHub.{CollectiveIntelligence, Repo}
  alias KiteAgentHub.Trading.{AgentConfigChange, KiteAgent, TradeRecord}

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

  @doc """
  Look up an agent by its on-chain `wallet_address`. Intended for
  **identity resolution only** — turning a public wallet address
  observed in a settled trade row / Kitescan into the owning agent
  record so callers can render attribution.

  ## DO NOT use this for authentication

  Wallet addresses are public on-chain (anyone reading Kitescan or
  the `trades` table has them). They contain no secret material and
  therefore prove nothing about who is making a request. **Never
  pass this function's result to an auth gate** — that is the bug
  PR #433 (F5) removed from ChatController, and the rule
  `TradesController:397-398` documents for the rest of the API.

  Token-based authentication goes through `get_agent_by_token/1`
  via the `AuthenticateAgent` plug. Wallet-based auth (if ever
  needed) requires a cryptographic signature challenge, not a bare
  address lookup.
  """
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
  @doc """
  User-driven chain_id mutation. Validates the new chain_id against
  `Kite.ChainId.valid_chain_ids/0` via `KiteAgent.chain_changeset/2`
  and writes an `agent_chain_changed` audit row on successful
  transition (CyberSec ask 6, msg 9212 — no-op saves skipped at the
  audit layer).

  Returns `{:ok, agent}` on success or `{:error, changeset}` on a
  validation failure. The audit write is soft-failure (logs, does
  not block the mutation) per the credential-audit pattern from
  PR #365.

  `actor_user_id` is required for the audit trail. Callers MUST
  thread it from `socket.assigns.current_scope.user.id`, not from
  request params.
  """
  def update_agent_chain(%KiteAgent{} = agent, %{"chain_id" => _} = attrs, actor_user_id)
      when not is_nil(actor_user_id) do
    changeset = KiteAgent.chain_changeset(agent, attrs)

    case Repo.update(changeset) do
      {:ok, updated} = ok ->
        KiteAgentHub.Audit.log_chain_change(
          actor_user_id,
          agent.organization_id,
          agent.id,
          agent.chain_id,
          updated.chain_id
        )

        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        ok

      err ->
        err
    end
  end

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
  Update an agent's `risk_config` and write a single
  `agent_config_changes` audit row in the same Repo.transaction. A
  failed validate, update, or audit insert rolls the whole thing back —
  partial saves (config persisted without an audit trail) are not
  reachable.

  `actor_user_id` is the integer users.id of the human who triggered
  the change; the form pulls it from the LiveView session, never from
  client-submitted params.
  """
  def update_agent_risk_config(%KiteAgent{} = agent, attrs, actor_user_id)
      when is_integer(actor_user_id) do
    changeset = KiteAgent.risk_config_changeset(agent, attrs)

    Multi.new()
    |> Multi.update(:agent, changeset)
    |> Multi.insert(:audit, fn %{agent: updated} ->
      AgentConfigChange.changeset(%AgentConfigChange{}, %{
        agent_id: updated.id,
        user_id: actor_user_id,
        prev_config: agent.risk_config || %{},
        new_config: updated.risk_config || %{}
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{agent: updated}} ->
        Phoenix.PubSub.broadcast(@pubsub, "agent:#{updated.id}", {:agent_updated, updated})
        {:ok, updated}

      {:error, :agent, %Ecto.Changeset{} = cs, _} ->
        {:error, cs}

      {:error, _step, reason, _} ->
        {:error, reason}
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

  # Server-side whitelist for sortable columns — only these atoms are
  # accepted from caller-supplied `:order_by`. Anything outside the list
  # falls back to `:inserted_at`. Defence-in-depth on top of the
  # whitelist already enforced at the TradesLive event boundary.
  @list_trades_sort_whitelist ~w[inserted_at fill_price contracts platform status action market notional_usd realized_pnl]a

  def list_trades(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    status = Keyword.get(opts, :status)
    platform = Keyword.get(opts, :platform)

    order_col =
      case Keyword.get(opts, :order_by) do
        col when col in @list_trades_sort_whitelist -> col
        _ -> :inserted_at
      end

    order_dir =
      case Keyword.get(opts, :order_dir) do
        :asc -> :asc
        _ -> :desc
      end

    TradeRecord
    |> where(kite_agent_id: ^agent_id)
    |> then(fn q -> if status, do: where(q, status: ^status), else: q end)
    |> then(fn q -> if platform, do: where(q, platform: ^platform), else: q end)
    |> order_by([t], [{^order_dir, field(t, ^order_col)}])
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

  @doc """
  Realized P&L for a settling SELL trade computed against the agent's
  prior settled BUY fills on the same `(platform, market)` (CyberSec
  ask 3, msg 9222 — scope is strictly (agent_id, platform, market)).
  Returns a `Decimal`.

  Buys / non-sell actions return `Decimal.new(0)` — there is nothing
  realized until the position is closed. Nil `fill_price` /
  `contracts` short-circuit to `Decimal.new(0)` so a broker row with
  partial data never crashes settlement (Phorari refinement,
  msg 9221).

  CyberSec ask 1 (msg 9222): every arithmetic step uses Decimal —
  zero Float coercion. Strings are cast via `Decimal.cast/1`.

  CyberSec ask 2 (msg 9222) — concurrent-settle:
  AlpacaSettlementWorker globally single-flights via
  `unique: [period: 30, fields: [:worker]]` and iterates trades
  sequentially; PaperExecutionWorker single-flights per
  `(agent_id, provider, symbol, side)`. Both modern paths guarantee
  no two sells on the same agent+market settle concurrently, so the
  FIFO read does not need a `SELECT FOR UPDATE`. The legacy
  `SettlementWorker` deduplicates on `args` only — concurrent
  same-market sells with different args are theoretically possible
  but the worker is on the way out and the read is followed
  immediately by `settle_trade/2`'s `Repo.update`; the window is
  microseconds. Documented; no DB-level lock added.
  """
  @spec compute_realized_pnl_for_sell(KiteAgentHub.Trading.TradeRecord.t()) :: Decimal.t()
  def compute_realized_pnl_for_sell(trade)

  def compute_realized_pnl_for_sell(%TradeRecord{action: "sell"} = trade) do
    with sell_price when not is_nil(sell_price) <- decimal_or_nil(trade.fill_price),
         qty when not is_nil(qty) <- decimal_or_nil(trade.contracts) do
      lots = prior_buy_lots(trade)
      {pnl, _remaining} = consume_fifo_lots(lots, qty, sell_price, Decimal.new(0))
      pnl
    else
      _ -> Decimal.new(0)
    end
  end

  def compute_realized_pnl_for_sell(_), do: Decimal.new(0)

  defp prior_buy_lots(%TradeRecord{} = sell) do
    TradeRecord
    |> where([t], t.kite_agent_id == ^sell.kite_agent_id)
    |> where([t], t.market == ^sell.market)
    |> where([t], t.platform == ^(sell.platform || "kite"))
    |> where([t], t.action == "buy")
    |> where([t], t.status == "settled")
    |> where([t], t.inserted_at <= ^sell.inserted_at)
    |> where([t], t.id != ^sell.id)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
    |> Enum.flat_map(fn buy ->
      case {decimal_or_nil(buy.contracts), decimal_or_nil(buy.fill_price)} do
        {nil, _} -> []
        {_, nil} -> []
        {qty, price} -> [{qty, price}]
      end
    end)
  end

  defp decimal_or_nil(nil), do: nil
  defp decimal_or_nil(%Decimal{} = d), do: d

  defp decimal_or_nil(value) when is_binary(value) or is_integer(value) or is_float(value) do
    case Decimal.cast(value) do
      {:ok, d} -> d
      :error -> nil
    end
  end

  defp decimal_or_nil(_), do: nil

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

  @doc """
  Cross-org sweep of open Kalshi trades older than `older_than_seconds`,
  preloading the agent so the reconciler can resolve `organization_id`
  to fetch broker credentials. Bypasses RLS (maintenance pattern, same
  as `ForexNavSnapshotPruner`) — invoked only from
  `KalshiOrderReconciler`, never a user-facing path.
  """
  def list_open_kalshi_trades_for_reconcile(opts \\ []) do
    older_than_seconds = Keyword.get(opts, :older_than_seconds, 60)
    limit_n = Keyword.get(opts, :limit, 200)
    cutoff = DateTime.add(DateTime.utc_now(), -older_than_seconds, :second)

    TradeRecord
    |> where([t], t.platform == "kalshi")
    |> where([t], t.status == "open")
    |> where([t], t.inserted_at < ^cutoff)
    |> order_by(asc: :inserted_at)
    |> limit(^limit_n)
    |> preload(:kite_agent)
    |> Repo.all()
  end

  def get_trade_for_agent(trade_id, agent_id) do
    Repo.get_by(TradeRecord, id: trade_id, kite_agent_id: agent_id)
  end

  # Find an unsubmitted pending trade for the same intent within a
  # short window. Used by `TradeExecutionWorker` to make Phase 1 of
  # the pending-row pattern idempotent across Oban retries — without a
  # `oban_job_id` column on the schema. Same (agent, market, action)
  # within `within_seconds` and still in the pre-broker state means a
  # prior attempt of the same job already inserted the row; reuse it
  # rather than inserting a duplicate (KAH P1 2026-05-07: 24 orphaned
  # pending rows from one agent across 8 symbols, 3x dupes per symbol
  # = Oban retries hitting unconditional create_trade).
  def find_pending_trade(agent_id, market, action, within_seconds \\ 300) do
    cutoff = DateTime.add(DateTime.utc_now(), -within_seconds, :second)

    TradeRecord
    |> where([t], t.kite_agent_id == ^agent_id)
    |> where([t], t.market == ^market)
    |> where([t], t.action == ^action)
    |> where([t], t.status == "pending")
    |> where([t], is_nil(t.broker_submitted_at))
    |> where([t], t.inserted_at >= ^cutoff)
    |> order_by(desc: :inserted_at)
    |> limit(1)
    |> Repo.one()
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

            async_record_outcome(updated)
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

          async_record_outcome(trade)
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
        async_record_outcome(trade)
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
      async_record_outcome(updated)
    end

    :ok
  end

  # Fire-and-forget recording of the trade outcome into the
  # Collective Intelligence corpus. This used to run synchronously
  # inside the calling worker's `Repo.with_user` transaction, which
  # held the parent connection through two extra DB ops per trade
  # update. Hands off to `KiteAgentHub.TaskSupervisor` so the work
  # runs after the caller's transaction closes — same RLS scope is
  # re-established briefly inside the task via `owner_user_id_for_agent`.
  #
  # Failure of the insight write does not affect the calling worker;
  # the trade row stands.
  defp async_record_outcome(%TradeRecord{} = trade) do
    if Application.get_env(:kite_agent_hub, :sync_record_outcome, false) do
      do_record_outcome(trade)
    else
      Task.Supervisor.start_child(KiteAgentHub.TaskSupervisor, fn ->
        do_record_outcome(trade)
      end)
    end

    :ok
  end

  defp do_record_outcome(%TradeRecord{} = trade) do
    case Repo.owner_user_id_for_agent(trade.kite_agent_id) do
      nil ->
        # No owner resolvable (orphaned trade row); record without
        # RLS scope. CI tables are tenant-keyed by source_org_hash
        # so this still lands cleanly.
        _ = CollectiveIntelligence.record_trade_outcome(trade)

      owner_user_id ->
        Repo.with_user(owner_user_id, fn ->
          CollectiveIntelligence.record_trade_outcome(trade)
        end)
    end
  rescue
    e ->
      require Logger

      Logger.warning(
        "Trading.async_record_outcome failed for trade #{trade.id}: #{Exception.message(e)}"
      )
  end

  def total_pnl(agent_id) do
    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "settled")
    |> Repo.aggregate(:sum, :realized_pnl) || Decimal.new(0)
  end

  @doc """
  Most recent `DrawdownGate` audit rows for an agent — newest first.
  Used by the Settings UI to render the audit log viewer alongside
  the threshold inputs so the user can see what their own rule did
  on each recent trade attempt.

  Scoped by `kite_agent_id`; never returns rows from another agent
  (DrawdownGate Phase 2a CyberSec ask 14192 #2).
  """
  def recent_dd_audit_for_agent(agent_id, limit \\ 20) when is_binary(agent_id) do
    from(a in KiteAgentHub.Trading.DdAuditLog,
      where: a.kite_agent_id == ^agent_id,
      order_by: [desc: a.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Sum of realized P&L for the given agent's trades that settled today
  (UTC). Used by `KiteAgentHub.Trading.DrawdownGate` to compute the
  realized-only daily-DD component.

  Returns a `Decimal` (zero when nothing has settled today). "Today"
  is the calendar day in UTC — the same boundary used by `last_equity`
  in the Alpaca account summary, so the two figures line up.
  """
  def today_realized_pnl_for_agent(agent_id) when is_binary(agent_id) do
    midnight_utc =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "settled")
    |> where([t], t.updated_at >= ^midnight_utc)
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
        # Capital deployed across all settled trades: fill_price ×
        # contracts. Denominator for the dashboard "Return %" card.
        # COALESCE keeps the sum at 0 when one leg is nil instead of
        # nullifying the whole row.
        total_notional:
          sum(
            fragment(
              "COALESCE(?, 0) * COALESCE(?, 0)",
              t.fill_price,
              t.contracts
            )
          ),
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
      total_notional: settled.total_notional || Decimal.new(0),
      win_count: settled.win_count || 0,
      loss_count: settled.loss_count || 0,
      trade_count: settled.trade_count || 0,
      open_count: open_count
    }
  end

  @doc """
  Bucketed historical-trade summary for one agent, scoped to settled
  rows (cancelled/failed/open are excluded — they have no learnable
  outcome). Returns a 4-shape map:

    * `:summary`     — totals across the agent (count, pnl, win rate)
    * `:by_platform` — per-platform aggregates (alpaca / kalshi / oanda)
    * `:by_market`   — per-symbol aggregates (top 20 by sample size)
    * `:recent`      — last N settled rows (default 20, max 100)

  Optional opts:
    * `:days`     — only include trades settled in the last N days
    * `:platform` — restrict to one platform string
    * `:limit`    — `:recent` sample size (clamped 1..100)

  Used by GET /api/v1/historical-trades so agents can reason about
  their own past outcomes (in addition to the cross-workspace KCI
  corpus from /collective-intelligence).
  """
  def historical_trades_summary(agent_id, opts \\ []) do
    days = Keyword.get(opts, :days)
    platform = Keyword.get(opts, :platform)
    limit = opts |> Keyword.get(:limit, 20) |> max(1) |> min(100)

    base =
      TradeRecord
      |> where(kite_agent_id: ^agent_id, status: "settled")
      |> then(fn q -> if platform, do: where(q, platform: ^platform), else: q end)
      |> then(fn q ->
        case days do
          n when is_integer(n) and n > 0 ->
            cutoff = DateTime.utc_now() |> DateTime.add(-n * 86_400, :second)
            where(q, [t], t.updated_at >= ^cutoff)

          _ ->
            q
        end
      end)

    summary =
      base
      |> select([t], %{
        settled_trades: count(t.id),
        total_pnl: sum(t.realized_pnl),
        win_count: sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        loss_count: sum(fragment("CASE WHEN ? < 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        flat_count: sum(fragment("CASE WHEN ? = 0 THEN 1 ELSE 0 END", t.realized_pnl))
      })
      |> Repo.one()

    by_platform =
      base
      |> group_by([t], t.platform)
      |> select([t], %{
        platform: t.platform,
        trades: count(t.id),
        wins: sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        losses: sum(fragment("CASE WHEN ? < 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        pnl: sum(t.realized_pnl)
      })
      |> order_by([t], desc: count(t.id))
      |> Repo.all()

    by_market =
      base
      |> group_by([t], t.market)
      |> select([t], %{
        market: t.market,
        trades: count(t.id),
        wins: sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        losses: sum(fragment("CASE WHEN ? < 0 THEN 1 ELSE 0 END", t.realized_pnl)),
        pnl: sum(t.realized_pnl)
      })
      |> order_by([t], desc: count(t.id))
      |> limit(20)
      |> Repo.all()

    recent =
      base
      |> order_by([t], desc: t.updated_at)
      |> limit(^limit)
      |> Repo.all()

    %{
      summary: summary,
      by_platform: by_platform,
      by_market: by_market,
      recent: recent
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
  PR-J.5.1: returns `%{market => attestation_tx_hash}` for every
  Kalshi trade belonging to the agent that has been attested.
  The dashboard Open Positions cards look up by market ticker and
  render a kitescan deep-link when present. The chain_id needed
  for the explorer URL comes from the owning `KiteAgent` (already
  available in socket assigns), per CyberSec ② msg 10911.

  Latest attestation wins on duplicate-market — `order_by desc`
  + `Map.new` overwrites earlier entries with newer ones.
  """
  def list_kalshi_attestations_for_agent(agent_id) do
    TradeRecord
    |> where(
      [t],
      t.kite_agent_id == ^agent_id and t.platform == "kalshi" and
        not is_nil(t.attestation_tx_hash)
    )
    |> order_by([t], asc: t.updated_at)
    |> select([t], {t.market, t.attestation_tx_hash})
    |> Repo.all()
    |> Map.new()
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
