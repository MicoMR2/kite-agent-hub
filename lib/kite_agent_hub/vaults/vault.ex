defmodule KiteAgentHub.Vaults.Vault do
  use Ecto.Schema
  import Ecto.Changeset

  schema "vaults" do
    field :encrypted_credentials, :binary
    field :iv, :binary

    belongs_to :user, KiteAgentHub.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :encrypted_credentials, :iv])
    |> validate_required([:user_id])
    |> unique_constraint(:user_id)
  end

  def put_payload_changeset(vault, ciphertext, iv) do
    vault
    |> cast(%{encrypted_credentials: ciphertext, iv: iv}, [:encrypted_credentials, :iv])
    |> validate_required([:encrypted_credentials, :iv])
  end
end
