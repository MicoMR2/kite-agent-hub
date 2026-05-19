defmodule KiteAgentHub.CollectiveIntelligence.TradeInsight do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `synthetic` rows are public-seed insights inserted by KciSeederWorker
  # from historical-data backtests — kept in a distinct bucket so callers
  # can filter them in or out depending on whether they want real-trade
  # outcomes only.
  @agent_types ~w(trading research conversational unknown synthetic)
  @platforms ~w(alpaca kalshi oanda_practice polymarket kite unknown)
  @market_classes ~w(equity option crypto forex prediction other)
  @outcome_buckets ~w(profit loss flat settled cancelled failed open)
  # PR-K3a: Kalshi-specific v2 fields. Nullable on v1 rows.
  @lifecycle_stages ~w(open settled cancelled expired)
  @prob_buckets ~w(0-10 10-20 20-30 30-40 40-50 50-60 60-70 70-80 80-90 90-100)
  @consent_versions ~w(kci-v1-2026-04-25 kci-v2-2026-05-19)

  schema "collective_trade_insights" do
    field :source_trade_hash, :string
    field :source_org_hash, :string
    field :agent_type, :string
    field :platform, :string
    field :market_class, :string
    field :side, :string
    field :action, :string
    field :status, :string
    field :outcome_bucket, :string
    field :notional_bucket, :string
    field :hold_time_bucket, :string
    field :observed_week, :date
    # PR-K3a v2 fields — populated only when the contributing org has
    # explicitly re-consented to kci-v2-2026-05-19 (write-time gate
    # in CollectiveIntelligence.record_trade_outcome/1 per CyberSec
    # 10831 ②).
    field :lifecycle_stage_at_exit, :string
    field :implied_prob_at_entry_bucket, :string
    field :consent_version, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(insight, attrs) do
    insight
    |> cast(attrs, [
      :source_trade_hash,
      :source_org_hash,
      :agent_type,
      :platform,
      :market_class,
      :side,
      :action,
      :status,
      :outcome_bucket,
      :notional_bucket,
      :hold_time_bucket,
      :observed_week,
      :lifecycle_stage_at_exit,
      :implied_prob_at_entry_bucket,
      :consent_version
    ])
    |> validate_required([
      :source_trade_hash,
      :source_org_hash,
      :agent_type,
      :platform,
      :market_class,
      :status,
      :outcome_bucket,
      :observed_week
    ])
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:market_class, @market_classes)
    |> validate_inclusion(:outcome_bucket, @outcome_buckets)
    |> validate_inclusion_if_set(:lifecycle_stage_at_exit, @lifecycle_stages)
    |> validate_inclusion_if_set(:implied_prob_at_entry_bucket, @prob_buckets)
    |> validate_inclusion_if_set(:consent_version, @consent_versions)
    |> unique_constraint(:source_trade_hash)
  end

  # Skip inclusion validation when the field is nil — v1 rows leave
  # the new v2 fields null and shouldn't trip validation. Only
  # validates when the field has been explicitly set.
  defp validate_inclusion_if_set(changeset, field, list) do
    case get_field(changeset, field) do
      nil -> changeset
      _ -> validate_inclusion(changeset, field, list)
    end
  end
end
