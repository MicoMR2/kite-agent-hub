defmodule KiteAgentHub.Wallets.Wallet do
  use Ecto.Schema
  import Ecto.Changeset

  schema "wallets" do
    field :balance_usd, :decimal, default: Decimal.new("0.00")
    field :currency, :string, default: "USD"

    belongs_to :user, KiteAgentHub.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "Internal changeset for creating an empty wallet for a user."
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :balance_usd, :currency])
    |> validate_required([:user_id])
    |> validate_inclusion(:currency, ~w(USD))
    |> unique_constraint(:user_id)
  end
end
