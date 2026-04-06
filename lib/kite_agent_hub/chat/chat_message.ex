defmodule KiteAgentHub.Chat.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sender_types ~w(user agent system)

  schema "chat_messages" do
    field :text, :string
    field :sender_type, :string
    field :sender_name, :string

    belongs_to :organization, KiteAgentHub.Orgs.Organization
    belongs_to :kite_agent, KiteAgentHub.Trading.KiteAgent
    belongs_to :user, KiteAgentHub.Accounts.User, type: :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [:text, :sender_type, :sender_name, :organization_id, :kite_agent_id, :user_id])
    |> validate_required([:text, :sender_type, :sender_name, :organization_id])
    |> validate_inclusion(:sender_type, @sender_types)
    |> strip_credentials()
  end

  # Strip any potential secrets from message text
  defp strip_credentials(changeset) do
    case get_change(changeset, :text) do
      nil -> changeset
      text ->
        cleaned = text
        |> String.replace(~r/-----BEGIN[A-Z ]+KEY-----[\s\S]*?-----END[A-Z ]+KEY-----/, "[REDACTED KEY]")
        |> String.replace(~r/sk-[a-zA-Z0-9]{20,}/, "[REDACTED]")
        |> String.replace(~r/swm_[a-zA-Z0-9]{20,}/, "[REDACTED]")
        put_change(changeset, :text, cleaned)
    end
  end
end
