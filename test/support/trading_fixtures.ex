defmodule KiteAgentHub.TradingFixtures do
  @moduledoc """
  Fixtures for Trading context tests — users/orgs/agents/trades under
  per-user RLS scope.
  """

  import KiteAgentHub.AccountsFixtures

  alias KiteAgentHub.{Orgs, Repo, Trading}
  alias KiteAgentHub.Trading.TradeRecord

  def agent_scope_fixture(attrs \\ %{}) do
    user = user_fixture()

    {:ok, org} =
      Orgs.create_org_for_user(user, %{name: "Org #{System.unique_integer([:positive])}"})

    {:ok, {:ok, agent}} =
      Repo.with_user(user.id, fn ->
        Trading.create_agent(
          Map.merge(
            %{
              name: "Agent #{System.unique_integer([:positive])}",
              organization_id: org.id,
              agent_type: "research",
              status: "active"
            },
            attrs
          )
        )
      end)

    %{user: user, org: org, agent: agent}
  end

  @doc """
  Insert a trade row directly. Trade inserts normally go through
  `Trading.create_trade/1` but tests want to backdate `inserted_at` to
  simulate a zombie — so we cast the changeset and force the timestamp
  via `Repo.insert!` under the owner's RLS scope.
  """
  def trade_fixture(%{user: user, agent: agent}, attrs \\ %{}) do
    defaults = %{
      market: "SLB",
      side: "long",
      action: "buy",
      contracts: 1,
      fill_price: Decimal.new("40.50"),
      status: "open",
      platform: "kite",
      kite_agent_id: agent.id
    }

    merged = Map.merge(defaults, attrs)
    inserted_at = Map.get(attrs, :inserted_at)

    {:ok, trade} =
      Repo.with_user(user.id, fn ->
        changeset = TradeRecord.changeset(%TradeRecord{}, merged)
        trade = Repo.insert!(changeset)

        if inserted_at do
          Ecto.Adapters.SQL.query!(
            Repo,
            "UPDATE trade_records SET inserted_at = $1 WHERE id = $2",
            [inserted_at, Ecto.UUID.dump!(trade.id)]
          )

          Repo.reload!(trade)
        else
          trade
        end
      end)

    trade
  end
end
