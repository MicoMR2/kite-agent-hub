defmodule KiteAgentHub.Trading.KiteAgent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending active paused error)
  @agent_types ~w(trading research conversational)

  schema "kite_agents" do
    field :name, :string
    field :agent_type, :string, default: "trading"
    field :wallet_address, :string
    field :vault_address, :string
    field :chain_id, :integer, default: 2368
    field :status, :string, default: "pending"
    field :api_token, :string

    belongs_to :organization, KiteAgentHub.Orgs.Organization
    has_many :trade_records, KiteAgentHub.Trading.TradeRecord

    timestamps(type: :utc_datetime)
  end

  # Full changeset — used on creation only
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :agent_type,
      :wallet_address,
      :vault_address,
      :chain_id,
      :status,
      :organization_id
    ])
    |> validate_required([:name, :organization_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:agent_type, @agent_types)
    |> validate_wallet_for_trading()
    |> validate_evm_address(:wallet_address)
    |> validate_evm_address(:vault_address)
    |> maybe_generate_api_token()
    |> unique_constraint(:wallet_address)
    |> unique_constraint(:api_token)
  end

  # Name-only update
  def name_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  defp validate_wallet_for_trading(changeset) do
    agent_type = get_field(changeset, :agent_type) || "trading"

    if agent_type == "trading" do
      validate_required(changeset, [:wallet_address])
    else
      changeset
    end
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

  defp maybe_generate_api_token(changeset) do
    if get_field(changeset, :api_token) do
      changeset
    else
      token = "kite_" <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
      put_change(changeset, :api_token, token)
    end
  end
end
