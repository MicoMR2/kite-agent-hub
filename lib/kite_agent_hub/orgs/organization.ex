defmodule KiteAgentHub.Orgs.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :collective_intelligence_enabled, :boolean, default: false
    field :collective_intelligence_consented_at, :utc_datetime
    field :collective_intelligence_consent_version, :string

    has_many :memberships, KiteAgentHub.Orgs.Membership
    has_many :users, through: [:memberships, :user]
    has_many :kite_agents, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug])
    |> validate_format(:slug, ~r/^[a-z0-9-]+$/,
      message: "only lowercase letters, numbers, and hyphens"
    )
    |> validate_length(:slug, min: 2, max: 60)
    |> unique_constraint(:slug)
  end

  def collective_intelligence_changeset(org, attrs) do
    org
    |> cast(attrs, [
      :collective_intelligence_enabled,
      :collective_intelligence_consented_at,
      :collective_intelligence_consent_version
    ])
    |> validate_required([:collective_intelligence_enabled])
  end
end
