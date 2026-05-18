defmodule KiteAgentHub.Forex.NavSnapshot do
  @moduledoc """
  Persisted tick of an agent's OANDA NAV. The Forex tab Session NAV
  sparkline (`DashboardLive` line ~5443) used to live entirely in
  socket state — a fresh tab open started with zero history and
  showed only the samples accumulated since mount.

  These rows back-fill that buffer so reopening the tab shows the
  agent's recent NAV trajectory instead of a flat baseline.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "forex_nav_snapshots" do
    # Unix-epoch seconds — matches the in-memory `{ts, nav}` ring
    # buffer shape so the LV seed path drops in without conversion.
    field :ts, :integer
    field :nav, :float

    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snap, attrs) do
    snap
    |> cast(attrs, [:kite_agent_id, :ts, :nav])
    |> validate_required([:kite_agent_id, :ts, :nav])
    |> validate_number(:ts, greater_than: 0)
  end
end
