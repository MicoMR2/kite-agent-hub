defmodule KiteAgentHub.Orgs.Membership do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(owner admin member)

  schema "org_memberships" do
    field :role, :string, default: "owner"

    belongs_to :user, KiteAgentHub.Accounts.User
    belongs_to :organization, KiteAgentHub.Orgs.Organization

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role, :user_id, :organization_id])
    |> validate_required([:role, :user_id, :organization_id])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:user_id, :organization_id])
  end
end
