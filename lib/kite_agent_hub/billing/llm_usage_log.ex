defmodule KiteAgentHub.Billing.LlmUsageLog do
  @moduledoc """
  One row per LLM call (internal) or per trade execution (BYO). The
  dashboard never charges against this table yet — it is a billing
  scaffold so future PRs can roll usage up by org without a back-fill.

  `source` records which pipeline produced the row:
    * `"internal"` — SignalEngine called a provider using an org key
    * `"byo_mcp"` — external client used the MCP server + agent token
    * `"byo_rest"` — external client POSTed directly to /api/v1/trades
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(internal byo_mcp byo_rest)

  schema "llm_usage_logs" do
    field :org_id, :binary_id
    field :agent_id, :binary_id
    field :provider, :string
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :cost_usd, :decimal
    field :source, :string, default: "internal"

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [
      :org_id,
      :agent_id,
      :provider,
      :model,
      :prompt_tokens,
      :completion_tokens,
      :cost_usd,
      :source
    ])
    |> validate_required([:org_id, :provider, :source])
    |> validate_inclusion(:source, @sources)
  end
end
