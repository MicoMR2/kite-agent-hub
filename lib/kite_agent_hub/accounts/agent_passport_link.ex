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

  # Public-identifier length cap (CyberSec ask 3, msg 9093). Passport
  # user/agent ids are well under this; longer values are rejected
  # before the pattern check.
  @public_id_max 256

  # JWT-shape reject (CyberSec ask 1, msg 9093). Any string field
  # whose value contains 2+ dots AND exceeds this length is treated
  # as a likely JWT/kpass token and rejected. 500 was chosen because
  # real JWTs are typically 800-1500 bytes and public Passport ids /
  # EVM addresses stay well under 256.
  @jwt_min_length 501

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
    |> validate_length(:passport_user_id, max: @public_id_max)
    |> validate_length(:passport_agent_id, max: @public_id_max)
    |> reject_jwt_shape(:passport_user_id)
    |> reject_jwt_shape(:passport_agent_id)
    |> reject_jwt_shape(:passport_wallet_address)
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

  # Non-custodial invariant guard: any cast field that looks like a
  # JWT (>500 bytes with 2+ dot separators) is rejected outright. The
  # error message intentionally does NOT echo the offending value
  # back (CyberSec ask 7, msg 9098 / 9100) — pasting a token into the
  # wrong field must not surface it in a flash or form error.
  defp reject_jwt_shape(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) ->
        if byte_size(value) >= @jwt_min_length and dot_count(value) >= 2 do
          add_error(changeset, field, "looks like a credential — paste only public Passport identifiers")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp dot_count(string) when is_binary(string) do
    string
    |> :binary.matches(".")
    |> length()
  end

  defp put_linked_at(changeset) do
    if get_field(changeset, :linked_at) do
      changeset
    else
      put_change(changeset, :linked_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end
end
