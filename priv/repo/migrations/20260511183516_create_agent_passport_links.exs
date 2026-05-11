defmodule KiteAgentHub.Repo.Migrations.CreateAgentPassportLinks do
  use Ecto.Migration

  def change do
    create table(:agent_passport_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id,
          references(:kite_agents, on_delete: :delete_all, type: :binary_id),
          null: false

      # Public-identifier-only columns. JWTs, kpass tokens, signing
      # authority NEVER touch this table — invariant from
      # passport-handoff.md §1.
      add :passport_user_id, :string, null: false
      add :passport_agent_id, :string, null: false
      add :passport_wallet_address, :string, null: false

      add :linked_at, :utc_datetime, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    # PR-4 (x402 receipt verify) will look up agents by the wallet that
    # signed the receipt; index the column up front so that lookup is
    # cheap from day one.
    create index(:agent_passport_links, [:passport_wallet_address])

    # Defense in depth: an agent can carry at most one active link at a
    # time. Partial unique index lets us soft-deactivate old links
    # without dropping their audit row.
    create unique_index(:agent_passport_links, [:agent_id],
             where: "active = true",
             name: :uniq_active_passport_per_agent
           )

    alter table(:kite_agents) do
      # `none`         — agent has not opted into either rail (default).
      # `subscription` — Rail A, monthly Stripe subscription.
      # `per_trade`    — Rail B, x402 fee per trade to the KAH vault.
      add :payment_rail, :string, null: false, default: "none"
    end
  end
end
