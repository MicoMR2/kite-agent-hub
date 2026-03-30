defmodule KiteAgentHub.Trading do
  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{KiteAgent, TradeRecord}

  # ── Agents ────────────────────────────────────────────────────────────────────

  def list_agents(org_id) do
    KiteAgent
    |> where(organization_id: ^org_id)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(KiteAgent, id)

  def get_agent_by_wallet(wallet_address) do
    Repo.get_by(KiteAgent, wallet_address: wallet_address)
  end

  def create_agent(attrs) do
    %KiteAgent{}
    |> KiteAgent.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%KiteAgent{} = agent, attrs) do
    agent
    |> KiteAgent.changeset(attrs)
    |> Repo.update()
  end

  def activate_agent(%KiteAgent{} = agent, vault_address) do
    agent
    |> KiteAgent.changeset(%{vault_address: vault_address, status: "active"})
    |> Repo.update()
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

  def count_open_trades(agent_id) do
    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "open")
    |> Repo.aggregate(:count)
  end

  def create_trade(attrs) do
    %TradeRecord{}
    |> TradeRecord.changeset(attrs)
    |> Repo.insert()
  end

  def settle_trade(%TradeRecord{} = record, pnl) do
    record
    |> TradeRecord.changeset(%{status: "settled", realized_pnl: pnl})
    |> Repo.update()
  end

  def total_pnl(agent_id) do
    TradeRecord
    |> where(kite_agent_id: ^agent_id, status: "settled")
    |> Repo.aggregate(:sum, :realized_pnl) || Decimal.new(0)
  end
end
