defmodule KiteAgentHub.Trading.AgentConfigChange do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_config_changes" do
    field :prev_config, :map, default: %{}
    field :new_config, :map, default: %{}

    belongs_to :agent, KiteAgentHub.Trading.KiteAgent
    belongs_to :user, KiteAgentHub.Accounts.User, type: :id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(audit, attrs) do
    audit
    |> cast(attrs, [:agent_id, :user_id, :prev_config, :new_config])
    |> validate_required([:agent_id, :user_id, :new_config])
    |> assoc_constraint(:agent)
    |> assoc_constraint(:user)
  end
end
