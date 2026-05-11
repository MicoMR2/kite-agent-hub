defmodule KiteAgentHub.Accounts.AgentPassportLink do
  @moduledoc """
  A linkage from a KAH trading agent to its Kite Passport identity.

  Stores **public identifiers only** — passport user id, passport agent
  id, and the agent's on-chain wallet address. JWTs / kpass tokens /
  signing authority never live here (or anywhere else in KAH state)
  per the non-custodial invariant in `passport-handoff.md` §1.

  Multi-link defense lives at the index layer: a unique partial index
  on `active = true` keeps an agent from carrying more than one live
  link simultaneously. Soft-deactivated rows stay around as an audit
  trail.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @wallet_re ~r/^0x[0-9a-fA-F]{40}$/

  schema "agent_passport_links" do
    belongs_to :agent, KiteAgentHub.Trading.KiteAgent

    field :passport_user_id, :string
    field :passport_agent_id, :string
    field :passport_wallet_address, :string

    field :linked_at, :utc_datetime
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :agent_id,
      :passport_user_id,
      :passport_agent_id,
      :passport_wallet_address,
      :linked_at,
      :active
    ])
    |> validate_required([
      :agent_id,
      :passport_user_id,
      :passport_agent_id,
      :passport_wallet_address
    ])
    |> validate_format(:passport_wallet_address, @wallet_re,
      message: "must be a 0x-prefixed 40-hex-character EVM address"
    )
    |> put_linked_at()
    |> unique_constraint(:agent_id,
      name: :uniq_active_passport_per_agent,
      message: "agent already has an active passport link"
    )
    |> foreign_key_constraint(:agent_id)
  end

  defp put_linked_at(changeset) do
    if get_field(changeset, :linked_at) do
      changeset
    else
      put_change(changeset, :linked_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
