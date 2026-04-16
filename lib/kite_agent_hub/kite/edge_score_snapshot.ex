defmodule KiteAgentHub.Kite.EdgeScoreSnapshot do
  @moduledoc """
  Persisted tick of a position's QRB edge score. Populated by
  `KiteAgentHub.Workers.EdgeScoreSnapshotWorker` every 5 minutes per
  active org; queried by `/api/v1/edge-scores/history` to call
  momentum inflections (HAL 96 → 91 → 85 = trim).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @platforms ~w(alpaca kalshi)
  @recommendations ~w(strong_hold hold watch exit)

  schema "edge_score_snapshots" do
    field :ticker, :string
    field :platform, :string
    field :score, :integer
    field :breakdown, :map, default: %{}
    field :recommendation, :string
    field :pnl_pct, :float

    belongs_to :organization, KiteAgentHub.Orgs.Organization

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snap, attrs) do
    snap
    |> cast(attrs, [
      :ticker,
      :platform,
      :score,
      :breakdown,
      :recommendation,
      :pnl_pct,
      :organization_id
    ])
    |> validate_required([:ticker, :platform, :score, :organization_id])
    |> validate_inclusion(:platform, @platforms)
    |> validate_inclusion(:recommendation, @recommendations ++ [nil])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
