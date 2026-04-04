defmodule KiteAgentHubWeb.DemoController do
  @moduledoc """
  One-click demo login for hackathon judges.

  GET /demo looks up the user by DEMO_USER_EMAIL env var and creates
  a session for them, redirecting to /dashboard. The demo user must
  be pre-created via the normal registration flow.

  On first login, auto-seeds a demo agent and sample trades so
  judges see a populated dashboard immediately.
  """

  use KiteAgentHubWeb, :controller

  alias KiteAgentHub.{Accounts, Orgs, Repo, Trading}
  alias KiteAgentHub.Trading.TradeRecord
  alias KiteAgentHubWeb.UserAuth

  @demo_wallet "0x95fCee8cbdDaa3285DCE7b51EfE196fFE6A3f347"

  def show(conn, _params) do
    case demo_user() do
      nil ->
        conn
        |> put_flash(:info, "Demo account not configured. Please sign in or register.")
        |> redirect(to: ~p"/users/log-in")

      user ->
        ensure_demo_agent(user)

        conn
        |> put_flash(:info, "Welcome! You are logged in as the demo account.")
        |> UserAuth.log_in_user(user)
    end
  end

  defp demo_user do
    case System.get_env("DEMO_USER_EMAIL") do
      nil -> nil
      "" -> nil
      email -> Accounts.get_user_by_email(email)
    end
  end

  defp ensure_demo_agent(user) do
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    if org do
      agents = Trading.list_agents(org.id)

      if agents == [] do
        seed_demo_data(org)
      end
    end
  end

  defp seed_demo_data(org) do
    case Trading.create_agent(%{
      "name" => "Demo Alpha Bot",
      "wallet_address" => @demo_wallet,
      "organization_id" => org.id,
      "daily_limit_usd" => 1000,
      "per_trade_limit_usd" => 500,
      "max_open_positions" => 10,
      "status" => "paused"
    }) do
      {:ok, agent} ->
        seed_sample_trades(agent)
        :ok

      {:error, _} ->
        :ok
    end
  end

  defp seed_sample_trades(agent) do
    now = DateTime.utc_now()

    trades = [
      %{
        market: "ETH-USDC",
        side: "long",
        action: "buy",
        contracts: 2,
        fill_price: Decimal.new("3245.50"),
        notional_usd: Decimal.new("6491.00"),
        status: "settled",
        platform: "alpaca",
        source: "demo",
        reason: "Bullish momentum signal — RSI 62, trend up"
      },
      %{
        market: "BTC-USDC",
        side: "long",
        action: "buy",
        contracts: 1,
        fill_price: Decimal.new("68420.00"),
        notional_usd: Decimal.new("68420.00"),
        status: "open",
        platform: "alpaca",
        source: "demo",
        reason: "Strong breakout above 68K resistance"
      },
      %{
        market: "ETH-USDC",
        side: "short",
        action: "sell",
        contracts: 1,
        fill_price: Decimal.new("3280.75"),
        notional_usd: Decimal.new("3280.75"),
        status: "settled",
        platform: "kite",
        source: "demo",
        reason: "RSI overbought at 74, taking profit",
        tx_hash: "0x" <> String.duplicate("a1b2c3d4", 8)
      },
      %{
        market: "SOL-USDC",
        side: "long",
        action: "buy",
        contracts: 5,
        fill_price: Decimal.new("178.30"),
        notional_usd: Decimal.new("891.50"),
        status: "open",
        platform: "alpaca",
        source: "demo",
        reason: "Solana ecosystem momentum, 24h +4.2%"
      }
    ]

    Enum.with_index(trades)
    |> Enum.each(fn {trade_attrs, idx} ->
      historical_ts = DateTime.add(now, -(idx + 1) * 1800, :second) |> DateTime.truncate(:second)

      %TradeRecord{}
      |> TradeRecord.changeset(Map.put(trade_attrs, :kite_agent_id, agent.id))
      |> Ecto.Changeset.force_change(:inserted_at, historical_ts)
      |> Ecto.Changeset.force_change(:updated_at, historical_ts)
      |> Repo.insert()
    end)
  end
end
