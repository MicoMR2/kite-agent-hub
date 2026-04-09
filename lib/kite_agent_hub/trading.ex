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
end
