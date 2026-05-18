defmodule KiteAgentHub.Trading.DdAuditLog do
  @moduledoc """
  Per-check audit row written by `KiteAgentHub.Trading.DrawdownGate`.

  Every gate evaluation produces one row regardless of outcome so the
  user can see what their own configured rule did (or didn't do) on
  each trade attempt. The framing matters legally — KAH executes the
  user's rule, never imposes its own — and the audit trail is what
  proves that.

  See `DrawdownGate` for the calling pattern.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @threshold_types ~w(halt flatten)
  # `allowed | blocked | skipped` are written by `DrawdownGate` on the
  # POST-trade hot path. `executed_close | close_failed` are written by
  # `KiteAgentHub.Workers.FlattenWorker` when the user-configured
  # flatten threshold actually fires a position unwind.
  @actions ~w(allowed blocked skipped executed_close close_failed)

  schema "agent_dd_audit_log" do
    field :threshold_type, :string
    field :threshold_value, :decimal
    field :equity, :float
    field :dd_pct, :float
    field :action, :string
    field :reason, :string

    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :kite_agent_id,
      :threshold_type,
      :threshold_value,
      :equity,
      :dd_pct,
      :action,
      :reason
    ])
    |> validate_required([:kite_agent_id, :threshold_type, :action])
    |> validate_inclusion(:threshold_type, @threshold_types)
    |> validate_inclusion(:action, @actions)
  end
end
