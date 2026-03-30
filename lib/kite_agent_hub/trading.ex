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

  def create_agent(attrs) do
    %KiteAgent{}
    |> KiteAgent.changeset(attrs)
    |> Repo.insert()
  end

  # General name update only — spending limits require explicit separate call
  def update_agent_name(%KiteAgent{} = agent, name) do
    agent
    |> KiteAgent.name_changeset(%{name: name})
    |> Repo.update()
  end

  # Spending limits are a privileged mutation — separate from general updates
  def update_spending_limits(%KiteAgent{} = agent, attrs) do
    agent
    |> KiteAgent.spending_limits_changeset(attrs)
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
    status = Keyword.get(opts, :status)

    TradeRecord
    |> where(kite_agent_id: ^agent_id)
    |> then(fn q -> if status, do: where(q, status: ^status), else: q end)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_open_trades(agent_id) do
    list_trades(agent_id, status: "open", limit: 200)
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
end
