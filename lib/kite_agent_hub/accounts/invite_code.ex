defmodule KiteAgentHub.Accounts.InviteCode do
  use Ecto.Schema
  import Ecto.Changeset

  schema "invite_codes" do
    field :code_hash, :binary
    field :email, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :used_by, KiteAgentHub.Accounts.User, foreign_key: :used_by_user_id
    belongs_to :created_by, KiteAgentHub.Accounts.User, foreign_key: :created_by_id
    belongs_to :access_request, KiteAgentHub.Accounts.AccessRequest

    field :code, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def insert_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:code_hash, :email, :expires_at, :created_by_id, :access_request_id])
    |> validate_required([:code_hash, :expires_at])
    |> update_change(:email, fn
      nil -> nil
      e -> String.downcase(e)
    end)
    |> unique_constraint(:code_hash)
  end
end
