defmodule KiteAgentHub.CollectiveIntelligence do
  @moduledoc """
  Privacy-preserving shared trade learning.

  Kite Collective Intelligence is workspace opt-in. It records only
  bucketed, anonymized trade outcome features and never stores raw user,
  agent, organization, broker credential, chat, or trade IDs in this table.
  """

  import Ecto.Query

  alias KiteAgentHub.CollectiveIntelligence.TradeInsight
  alias KiteAgentHub.Orgs.Organization
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Trading.{OccSymbol, TradeRecord}

  @consent_version "kci-v1-2026-04-25"
  @crypto_markets ~w(BTCUSD ETHUSD SOLUSD BTC-USDC ETH-USDC SOL-USDC)

  def consent_version, do: @consent_version

  def enabled_for_org?(org_id) when is_binary(org_id) do
    case fetch_org(org_id) do
      %Organization{collective_intelligence_enabled: true} -> true
      _ -> false
    end
  end

  def enabled_for_org?(_org_id), do: false

  def record_trade_outcome(%TradeRecord{} = trade) do
    trade = Repo.preload(trade, :kite_agent)

    with %{kite_agent: %{organization_id: org_id}} <- trade,
         true <- enabled_for_org?(org_id),
         {:ok, attrs} <- insight_attrs(trade, org_id) do
      %TradeInsight{}
      |> TradeInsight.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing, conflict_target: :source_trade_hash)
      |> case do
        {:ok, _insight} -> :ok
        {:error, _changeset} = err -> err
      end
    else
      _ -> :ok
    end
  end

  @doc """
  Insert a synthetic / public-seed insight directly. Used by the
  KciSeederWorker to bootstrap the corpus from public market-data
  backtests so new agents have something to read on day 1, before
  any user trade has settled.

  Caller must supply:
    * `:source_trade_hash` — deterministic so reruns are idempotent
      (insert uses on_conflict: :nothing against the unique index)
    * `:source_org_hash`   — typically `source_hash("seed", "v1")` so
      seeded rows are clearly bucketed apart from real org contributions
    * the same shape fields a real record_trade_outcome would build
      (agent_type, platform, market_class, side, action, status,
      outcome_bucket, notional_bucket, hold_time_bucket, observed_week)

  No org-opt-in check here — public seed data is publicly contributed
  by design (it does not represent any real user). The reciprocity
  gate at /api/v1/collective-intelligence is independent.
  """
  def record_synthetic_outcome(attrs) when is_map(attrs) do
    %TradeInsight{}
    |> TradeInsight.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :source_trade_hash)
    |> case do
      {:ok, _insight} -> :ok
      {:error, _changeset} = err -> err
    end
  end

  @doc """
  Public helper for the Seeder so it can derive deterministic seed
  hashes without poking at private functions. Same HMAC + salt as
  the real-trade path so seeded rows can never collide with real
  org_id hashes.
  """
  def seed_hash(kind, value), do: source_hash(kind, value)

  def purge_org_contributions(org_id) when is_binary(org_id) do
    source_org_hash = source_hash("org", org_id)

    {count, _} =
      TradeInsight
      |> where([i], i.source_org_hash == ^source_org_hash)
      |> Repo.delete_all()

    count
  end

  def purge_org_contributions(_org_id), do: 0

  def summary_for_org(org_id, opts \\ []) do
    if enabled_for_org?(org_id) do
      limit = opts |> Keyword.get(:limit, 8) |> min(25) |> max(1)

      insights =
        TradeInsight
        |> group_by([i], [i.platform, i.market_class, i.side, i.action])
        |> select([i], %{
          platform: i.platform,
          market_class: i.market_class,
          side: i.side,
          action: i.action,
          sample_size: count(i.id),
          wins: fragment("SUM(CASE WHEN ? = 'profit' THEN 1 ELSE 0 END)", i.outcome_bucket),
          losses: fragment("SUM(CASE WHEN ? = 'loss' THEN 1 ELSE 0 END)", i.outcome_bucket),
          flats: fragment("SUM(CASE WHEN ? = 'flat' THEN 1 ELSE 0 END)", i.outcome_bucket)
        })
        |> order_by([i], desc: count(i.id))
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(&format_insight/1)

      %{
        enabled: true,
        name: "Kite Collective Intelligence",
        consent_version: @consent_version,
        privacy: "anonymized, bucketed, opt-in trade outcome learning",
        notes:
          "Includes both real opt-in user trades (agent_type in trading/research/conversational) and public-seed synthetic backtests (agent_type=synthetic). Filter by agent_type if you want one or the other.",
        insights: insights
      }
    else
      %{
        enabled: false,
        name: "Kite Collective Intelligence",
        consent_version: @consent_version,
        privacy: "disabled for this workspace",
        insights: []
      }
    end
  end

  defp insight_attrs(%TradeRecord{} = trade, org_id) do
    {:ok,
     %{
       source_trade_hash: source_hash("trade", trade.id),
       source_org_hash: source_hash("org", org_id),
       agent_type: agent_type(trade),
       platform: normalize_platform(trade.platform),
       market_class: market_class(trade),
       side: trade.side,
       action: trade.action,
       status: trade.status || "open",
       outcome_bucket: outcome_bucket(trade),
       notional_bucket: notional_bucket(trade),
       hold_time_bucket: hold_time_bucket(trade),
       observed_week: observed_week(trade)
     }}
  end

  defp fetch_org(org_id) do
    case KiteAgentHub.Orgs.get_org_owner_user_id(org_id) do
      nil ->
        Repo.get(Organization, org_id)

      owner_user_id ->
        case Repo.with_user(owner_user_id, fn -> Repo.get(Organization, org_id) end) do
          {:ok, org} -> org
          _ -> nil
        end
    end
  end

  defp format_insight(row) do
    wins = row.wins || 0
    losses = row.losses || 0
    flats = row.flats || 0
    resolved = wins + losses + flats
    win_rate = if resolved > 0, do: Float.round(wins / resolved * 100, 1), else: nil

    %{
      platform: row.platform,
      market_class: row.market_class,
      side: row.side,
      action: row.action,
      sample_size: row.sample_size,
      wins: wins,
      losses: losses,
      flats: flats,
      win_rate: win_rate,
      lesson: lesson_text(row, win_rate)
    }
  end

  defp lesson_text(row, nil) do
    "#{label(row)} has #{row.sample_size} anonymized sample(s), but no directional P&L signal yet."
  end

  defp lesson_text(row, win_rate) do
    "#{label(row)} shows a #{win_rate}% profit rate across #{row.sample_size} anonymized sample(s). Use as context, not a guarantee."
  end

  defp label(row) do
    [row.platform, row.market_class, row.side, row.action]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp agent_type(%{kite_agent: %{agent_type: type}})
       when type in ~w(trading research conversational),
       do: type

  defp agent_type(_trade), do: "unknown"

  defp normalize_platform(nil), do: "unknown"
  defp normalize_platform("oanda"), do: "oanda_practice"

  defp normalize_platform(platform)
       when platform in ~w(alpaca kalshi oanda_practice polymarket kite), do: platform

  defp normalize_platform(_platform), do: "unknown"

  defp market_class(%TradeRecord{platform: platform}) when platform in ["kalshi", "polymarket"],
    do: "prediction"

  defp market_class(%TradeRecord{market: market}) when is_binary(market) do
    cond do
      market in @crypto_markets -> "crypto"
      OccSymbol.match?(market) -> "option"
      Regex.match?(~r/\A[A-Z]{3}_[A-Z]{3}\z/, market) -> "forex"
      Regex.match?(~r/\A[A-Z]{1,6}\z/, market) -> "equity"
      true -> "other"
    end
  end

  defp market_class(_trade), do: "other"

  defp outcome_bucket(%TradeRecord{status: status})
       when status in ["cancelled", "failed", "open"],
       do: status

  defp outcome_bucket(%TradeRecord{realized_pnl: nil}), do: "flat"

  defp outcome_bucket(%TradeRecord{realized_pnl: pnl}) do
    cond do
      Decimal.gt?(pnl, 0) -> "profit"
      Decimal.lt?(pnl, 0) -> "loss"
      true -> "flat"
    end
  end

  defp notional_bucket(%TradeRecord{} = trade) do
    notional =
      trade.notional_usd ||
        if trade.fill_price && trade.contracts do
          Decimal.mult(trade.fill_price, Decimal.new(trade.contracts))
        end

    cond do
      is_nil(notional) -> "unknown"
      Decimal.lt?(notional, Decimal.new("100")) -> "under_100"
      Decimal.lt?(notional, Decimal.new("1000")) -> "100_to_999"
      Decimal.lt?(notional, Decimal.new("10000")) -> "1000_to_9999"
      true -> "10000_plus"
    end
  end

  defp hold_time_bucket(%TradeRecord{inserted_at: nil}), do: "unknown"
  defp hold_time_bucket(%TradeRecord{updated_at: nil}), do: "unknown"

  defp hold_time_bucket(%TradeRecord{inserted_at: inserted_at, updated_at: updated_at}) do
    seconds = DateTime.diff(updated_at, inserted_at, :second)

    cond do
      seconds < 5 * 60 -> "under_5m"
      seconds < 60 * 60 -> "5m_to_1h"
      seconds < 24 * 60 * 60 -> "1h_to_1d"
      true -> "over_1d"
    end
  end

  defp observed_week(%TradeRecord{updated_at: %DateTime{} = dt}), do: week_start(dt)
  defp observed_week(%TradeRecord{inserted_at: %DateTime{} = dt}), do: week_start(dt)
  defp observed_week(_trade), do: Date.utc_today() |> Date.beginning_of_week(:monday)

  defp week_start(%DateTime{} = dt) do
    dt
    |> DateTime.to_date()
    |> Date.beginning_of_week(:monday)
  end

  defp source_hash(kind, value) do
    :hmac
    |> :crypto.mac(:sha256, salt(), "#{kind}:#{value}")
    |> Base.encode16(case: :lower)
  end

  # Salt resolution chain:
  #   1. :collective_intelligence_salt  (set in runtime.exs from
  #      COLLECTIVE_INTELLIGENCE_SALT — required in prod, runtime.exs
  #      raises if missing).
  #   2. KiteAgentHubWeb.Endpoint :secret_key_base — soft fallback for
  #      historical envs only, with a loud warning so the operator
  #      knows the privacy promise depends on shared key state.
  #   3. Hardcoded dev/test constant — only safe because :prod is
  #      blocked at boot by the runtime.exs check above.
  @dev_salt "kite-collective-intelligence-dev-salt"

  defp salt do
    case Application.get_env(:kite_agent_hub, :collective_intelligence_salt) do
      salt when is_binary(salt) and byte_size(salt) > 0 ->
        salt

      _ ->
        case get_in(Application.get_env(:kite_agent_hub, KiteAgentHubWeb.Endpoint, []), [
               :secret_key_base
             ]) do
          base when is_binary(base) and byte_size(base) > 0 ->
            require Logger

            Logger.warning(
              "CollectiveIntelligence: falling back to Endpoint :secret_key_base for KCI salt. " <>
                "Set COLLECTIVE_INTELLIGENCE_SALT (Fly secret) so opt-out purges survive a key rotation."
            )

            base

          _ ->
            @dev_salt
        end
    end
  end
end
