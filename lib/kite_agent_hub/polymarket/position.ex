defmodule KiteAgentHub.Polymarket.Position do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @outcomes ~w(yes no)
  @modes ~w(paper live)
  @statuses ~w(open closed)

  schema "polymarket_positions" do
    field :market_id, :string
    field :token_id, :string
    field :outcome, :string
    field :size, :decimal, default: Decimal.new(0)
    field :avg_price, :decimal, default: Decimal.new(0)
    field :realized_pnl, :decimal, default: Decimal.new(0)
    field :mode, :string, default: "paper"
    field :status, :string, default: "open"

    field :organization_id, :binary_id
    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime)
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, [
      :market_id,
      :token_id,
      :outcome,
      :size,
      :avg_price,
      :realized_pnl,
      :mode,
      :status,
      :organization_id,
      :kite_agent_id
    ])
    |> validate_required([
      :market_id,
      :token_id,
      :outcome,
      :organization_id
    ])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> validate_format(:market_id, ~r/^(0x[a-fA-F0-9]+|[0-9a-fA-F\-]{8,})$/,
      message: "must be a hex hash or uuid-like id"
    )
    |> validate_format(:token_id, ~r/^[0-9a-fA-Fx\-]+$/,
      message: "must be numeric or hex"
    )
  end
end
