defmodule KiteAgentHub.Trading.KiteAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active paused error)

  schema "kite_agents" do
    field :name, :string
    field :wallet_address, :string
    field :vault_address, :string
    field :chain_id, :integer, default: 2368
    field :daily_limit_usd, :integer, default: 1000
    field :per_trade_limit_usd, :integer, default: 500
    field :max_open_positions, :integer, default: 10
    field :status, :string, default: "pending"

    belongs_to :organization, KiteAgentHub.Orgs.Organization
    has_many :trade_records, KiteAgentHub.Trading.TradeRecord

    timestamps(type: :utc_datetime)
  end

  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :wallet_address, :vault_address, :chain_id,
                    :daily_limit_usd, :per_trade_limit_usd, :max_open_positions,
                    :status, :organization_id])
    |> validate_required([:name, :wallet_address, :organization_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:daily_limit_usd, greater_than: 0)
    |> validate_number(:per_trade_limit_usd, greater_than: 0)
    |> validate_number(:max_open_positions, greater_than: 0)
    |> unique_constraint(:wallet_address)
  end
end
