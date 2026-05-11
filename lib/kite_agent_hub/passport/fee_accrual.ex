defmodule KiteAgentHub.Passport.FeeAccrual do
  @moduledoc """
  Audit record for a Rail-B per-trade fee paid to the KAH vault via
  x402. Stores the public payment-receipt blob, the amount that
  cleared, the agent it came from, and (when available) the trade
  row it was paid against.

  Receipt strings are unique at the DB layer — the migration creates
  `unique_index(:fee_accruals, [:x402_receipt])` so a replay attempt
  with the same receipt comes back as a constraint violation
  (409 Conflict at the controller).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_receipt_bytes 4096

  schema "fee_accruals" do
    belongs_to :agent, KiteAgentHub.Trading.KiteAgent
    belongs_to :trade, KiteAgentHub.Trading.TradeRecord

    field :x402_receipt, :string
    field :amount_usdc, :decimal
    field :accrued_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:agent_id, :trade_id, :x402_receipt, :amount_usdc, :accrued_at])
    |> validate_required([:x402_receipt, :amount_usdc])
    |> validate_length(:x402_receipt, max: @max_receipt_bytes)
    |> put_accrued_at()
    |> unique_constraint(:x402_receipt)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:trade_id)
  end

  defp put_accrued_at(changeset) do
    if get_field(changeset, :accrued_at) do
      changeset
    else
      put_change(
        changeset,
        :accrued_at,
        DateTime.utc_now() |> DateTime.truncate(:second)
      )
    end
  end
end
