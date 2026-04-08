defmodule KiteAgentHub.Trading.TradeRecord do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open settled cancelled failed)
  @sides ~w(yes no long short buy sell)
  @actions ~w(buy sell)
  @platforms ~w(kite alpaca kalshi)

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
    field :platform, :string, default: "kite"
    field :platform_order_id, :string
    field :attestation_tx_hash, :string

    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime)
  end

  # Insert-only changeset — tx_hash and trade_id_onchain are set on creation, never updated
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :trade_id_onchain,
      :tx_hash,
      :market,
      :side,
      :action,
      :contracts,
      :fill_price,
      :notional_usd,
      :status,
      :realized_pnl,
      :source,
      :reason,
      :platform,
      :platform_order_id,
      :kite_agent_id
    ])
    |> validate_required([:market, :side, :action, :contracts, :fill_price, :kite_agent_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:platform, @platforms)
    |> validate_number(:contracts, greater_than: 0)
    |> lock_immutable_fields()
  end

  # Settle-only changeset — only status and pnl can change after insert
  def settle_changeset(record, pnl) do
    record
    |> cast(%{status: "settled", realized_pnl: pnl}, [:status, :realized_pnl])
    |> validate_inclusion(:status, @statuses)
  end

  # Attestation-only changeset — only attestation_tx_hash can change.
  # Used by KiteAttestationWorker after submitting the settlement
  # transfer to the Kite chain relayer. Insert-once, immutable after.
  def attestation_changeset(record, tx_hash) when is_binary(tx_hash) do
    record
    |> cast(%{attestation_tx_hash: tx_hash}, [:attestation_tx_hash])
    |> validate_required([:attestation_tx_hash])
    |> lock_field(:attestation_tx_hash)
  end

  # tx_hash and trade_id_onchain cannot be changed after insert
  defp lock_immutable_fields(changeset) do
    changeset
    |> lock_field(:tx_hash)
    |> lock_field(:trade_id_onchain)
  end

  defp lock_field(changeset, field) do
    if Map.get(changeset.data, field) != nil && get_change(changeset, field) do
      add_error(changeset, field, "cannot be changed after insert")
    else
      changeset
    end
  end
end
