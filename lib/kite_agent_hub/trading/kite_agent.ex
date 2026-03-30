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

  # Full changeset — used on creation only
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :wallet_address,
      :vault_address,
      :chain_id,
      :daily_limit_usd,
      :per_trade_limit_usd,
      :max_open_positions,
      :status,
      :organization_id
    ])
    |> validate_required([:name, :wallet_address, :organization_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_evm_address(:wallet_address)
    |> validate_evm_address(:vault_address)
    |> validate_spending_limits()
    |> unique_constraint(:wallet_address)
  end

  # Name-only update — spending limits never touched
  def name_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  # Privileged — spending limits require explicit mutation, not general form update
  def spending_limits_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:daily_limit_usd, :per_trade_limit_usd, :max_open_positions])
    |> validate_spending_limits()
  end

  defp validate_evm_address(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, value) do
        []
      else
        [{field, "must be a valid EVM address (0x + 40 hex chars)"}]
      end
    end)
  end

  defp validate_spending_limits(changeset) do
    changeset
    |> validate_number(:daily_limit_usd, greater_than: 0)
    |> validate_number(:per_trade_limit_usd, greater_than: 0)
    |> validate_number(:max_open_positions, greater_than: 0)
  end
end
