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

  @consent_version "kci-v2-2026-05-19"
  @prior_consent_version "kci-v1-2026-04-25"
  @crypto_markets ~w(BTCUSD ETHUSD SOLUSD BTC-USDC ETH-USDC SOL-USDC)

  # PR-K3a: minimum distinct contributing orgs on a Kalshi market
  # before its outcomes can be recorded. k=10 floor per CyberSec
  # 10831 ③ + Phorari 10832 lock. Cross-field anonymity (ticker ×
  # lifecycle × prob bucket × existing v1 fields) is the actual
  # surface protected — see `kalshi_market_anonymity_safe?/1`.
  @kalshi_k_anonymity_floor 10

  def consent_version, do: @consent_version
  def prior_consent_version, do: @prior_consent_version

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
         {:ok, attrs} <- insight_attrs(trade, org_id),
         :ok <- gate_kalshi_anonymity(trade, attrs) do
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

  # PR-K3a write-time anonymity gate (CyberSec 10831 ③ + ④). Only
  # applies to Kalshi rows that would carry v2 fields. The check
  # counts distinct organizations that have traded the same Kalshi
  # market across the global trade_records table — if fewer than
  # `@kalshi_k_anonymity_floor` distinct orgs have ever touched the
  # market, the row is dropped entirely (no DB write). This protects
  # the cross-field combination (ticker × lifecycle × prob bucket ×
  # existing v1 fields) on low-population KX markets.
  defp gate_kalshi_anonymity(%TradeRecord{platform: "kalshi"} = trade, %{
         lifecycle_stage_at_exit: stage
       })
       when not is_nil(stage) do
    if kalshi_market_anonymity_safe?(trade.market), do: :ok, else: {:gated, :low_population}
  end

  defp gate_kalshi_anonymity(_trade, _attrs), do: :ok

  @doc false
  # Exported for hermetic tests. Returns true when the Kalshi market
  # has been traded by `@kalshi_k_anonymity_floor` or more distinct
  # organizations across `trade_records`. The check is against the
  # actual contributor pool (orgs that have placed a trade), not the
  # already-inserted KCI rows — that closes the chicken-and-egg gap
  # where the first 9 inserts could never land.
  def kalshi_market_anonymity_safe?(ticker) when is_binary(ticker) do
    import Ecto.Query
    alias KiteAgentHub.Trading.KiteAgent

    count =
      from(t in TradeRecord,
        join: a in KiteAgent,
        on: a.id == t.kite_agent_id,
        where: t.platform == "kalshi" and t.market == ^ticker,
        distinct: a.organization_id,
        select: a.organization_id
      )
      |> Repo.aggregate(:count)

    count >= @kalshi_k_anonymity_floor
  end

  def kalshi_market_anonymity_safe?(_), do: false

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

  @doc """
  Backfill the corpus with every previously-settled trade for an org.

  When a workspace opts in to KCI AFTER they have already settled
  trades, those rows have not been recorded into the corpus — only
  trades that flip to a terminal status AFTER opt-in fire the hook.
  This function walks every settled / cancelled / failed trade for
  the given org and replays `record_trade_outcome` so the historical
  contributions get credited.

  Idempotent: every TradeInsight insert already uses
  `on_conflict: :nothing` against the unique `source_trade_hash`
  index, so re-running this does not produce duplicates.

  Returns `{:ok, %{processed: n, inserted: m, skipped: k}}` where
  - `processed` = trades scanned
  - `inserted`  = new insights actually added (rest were idempotent re-tries)
  - `skipped`   = trades that record_trade_outcome filtered (open / no-org)

  Op-safe: respects the org's opt-in. If the org is not opted in,
  returns `{:error, :kci_not_enabled}` instead of silently doing
  nothing.
  """
  def backfill_org(org_id) when is_binary(org_id) do
    if enabled_for_org?(org_id) do
      import Ecto.Query
      alias KiteAgentHub.Trading.KiteAgent

      # Find all trades belonging to agents in this org. We scan
      # settled/cancelled/failed (the terminal statuses
      # record_trade_outcome cares about); open rows have no outcome.
      query =
        from t in TradeRecord,
          join: a in KiteAgent,
          on: a.id == t.kite_agent_id,
          where: a.organization_id == ^org_id,
          where: t.status in ["settled", "cancelled", "failed"],
          order_by: [asc: t.inserted_at]

      trades = Repo.all(query)

      counts =
        Enum.reduce(trades, %{processed: 0, inserted: 0, skipped: 0}, fn trade, acc ->
          before_count = Repo.aggregate(TradeInsight, :count)

          case record_trade_outcome(trade) do
            :ok ->
              after_count = Repo.aggregate(TradeInsight, :count)
              new_row? = after_count > before_count

              %{
                acc
                | processed: acc.processed + 1,
                  inserted: acc.inserted + if(new_row?, do: 1, else: 0)
              }

            _ ->
              %{acc | processed: acc.processed + 1, skipped: acc.skipped + 1}
          end
        end)

      {:ok, counts}
    else
      {:error, :kci_not_enabled}
    end
  end

  def backfill_org(_org_id), do: {:error, :invalid_org_id}

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
    base = %{
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
    }

    {:ok, maybe_add_v2_kalshi_fields(base, trade, org_id)}
  end

  # PR-K3a v2 Kalshi-specific buckets. Populated only when:
  #   1. The trade is on the kalshi platform, AND
  #   2. The owning org has explicitly re-consented to kci-v2
  #
  # v1-consented orgs continue contributing the platform-generic
  # base attrs above; the v2 columns stay null in their inserts.
  # CyberSec 10831 ② write-time enforcement.
  defp maybe_add_v2_kalshi_fields(attrs, %TradeRecord{platform: "kalshi"} = trade, org_id) do
    if org_consent_version(org_id) == @consent_version do
      Map.merge(attrs, %{
        lifecycle_stage_at_exit: kalshi_lifecycle_stage(trade),
        implied_prob_at_entry_bucket: kalshi_prob_bucket(trade.fill_price),
        consent_version: @consent_version
      })
    else
      attrs
    end
  end

  defp maybe_add_v2_kalshi_fields(attrs, _trade, _org_id), do: attrs

  defp org_consent_version(org_id) do
    case fetch_org(org_id) do
      %Organization{collective_intelligence_consent_version: v} -> v
      _ -> nil
    end
  end

  defp kalshi_lifecycle_stage(%TradeRecord{status: status})
       when status in ["settled", "cancelled", "expired"],
       do: status

  defp kalshi_lifecycle_stage(_), do: "open"

  # Bucket the Kalshi entry price (stored as a 0..1 implied prob in
  # the TradeRecord fill_price decimal) into the 10 fixed buckets the
  # schema validates against. Defaults to nil (skipped at the row
  # level) when fill_price isn't usable as a probability.
  defp kalshi_prob_bucket(%Decimal{} = fill_price) do
    case Decimal.to_float(fill_price) do
      p when is_number(p) and p >= 0 and p <= 1 -> prob_bucket_label(p)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp kalshi_prob_bucket(_), do: nil

  defp prob_bucket_label(p) when p < 0.1, do: "0-10"
  defp prob_bucket_label(p) when p < 0.2, do: "10-20"
  defp prob_bucket_label(p) when p < 0.3, do: "20-30"
  defp prob_bucket_label(p) when p < 0.4, do: "30-40"
  defp prob_bucket_label(p) when p < 0.5, do: "40-50"
  defp prob_bucket_label(p) when p < 0.6, do: "50-60"
  defp prob_bucket_label(p) when p < 0.7, do: "60-70"
  defp prob_bucket_label(p) when p < 0.8, do: "70-80"
  defp prob_bucket_label(p) when p < 0.9, do: "80-90"
  defp prob_bucket_label(_), do: "90-100"

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
