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
      :observed_week
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
    |> unique_constraint(:source_trade_hash)
  end
end
