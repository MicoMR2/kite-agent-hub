defmodule KiteAgentHub.Trading.TradeRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open settled cancelled failed)
  @sides ~w(yes no)
  @actions ~w(buy sell)

  schema "trade_records" do
    field :trade_id_onchain, :string
    field :tx_hash, :string
    field :market, :string
    field :side, :string
    field :action, :string
    field :contracts, :integer
    field :fill_price, :decimal
    field :notional_usd, :decimal
    field :status, :string, default: "open"
    field :realized_pnl, :decimal
    field :source, :string
    field :reason, :string

    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:trade_id_onchain, :tx_hash, :market, :side, :action,
                    :contracts, :fill_price, :notional_usd, :status,
                    :realized_pnl, :source, :reason, :kite_agent_id])
    |> validate_required([:market, :side, :action, :contracts, :fill_price, :kite_agent_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:action, @actions)
    |> validate_number(:contracts, greater_than: 0)
  end
end
