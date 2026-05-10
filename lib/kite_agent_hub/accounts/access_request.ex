defmodule KiteAgentHub.Accounts.AccessRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved rejected)

  schema "access_requests" do
    field :name, :string
    field :email, :string
    field :notes, :string
    field :status, :string, default: "pending"
    field :processed_at, :utc_datetime

    belongs_to :processed_by, KiteAgentHub.Accounts.User, foreign_key: :processed_by_id

    timestamps(type: :utc_datetime)
  end

  def request_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:name, :email, :notes])
    |> validate_required([:name, :email])
    |> validate_length(:name, max: 160)
    |> validate_length(:notes, max: 2000)
    |> update_change(:email, fn e -> e |> String.trim() |> String.downcase() end)
    |> update_change(:name, &String.trim/1)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/, message: "must be a valid email")
    |> validate_length(:email, max: 160)
  end

  def status_changeset(req, status, processed_by_id) when status in @statuses do
    req
    |> change(%{
      status: status,
      processed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      processed_by_id: processed_by_id
    })
  end
end
