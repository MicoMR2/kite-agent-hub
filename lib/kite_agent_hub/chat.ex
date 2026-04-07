defmodule KiteAgentHub.Chat do
  @moduledoc """
  Context for the in-platform chat messenger.
  Messages are scoped to an organization (user's workspace).
  PubSub broadcasts are scoped to org_id to prevent cross-org leaks.
  """

  import Ecto.Query
  alias KiteAgentHub.Repo
  alias KiteAgentHub.Chat.ChatMessage

  @pubsub KiteAgentHub.PubSub

  @type message :: %ChatMessage{}

  @doc "List recent messages for an org, oldest first."
  @spec list_messages(Ecto.UUID.t(), keyword()) :: [message()]
  def list_messages(org_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    ChatMessage
    |> where([m], m.organization_id == ^org_id)
    |> order_by([m], desc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  @doc "Send a message from a user. Credentials are stripped in the changeset before persistence."
  @spec send_user_message(Ecto.UUID.t(), map(), String.t()) :: {:ok, message()} | {:error, Ecto.Changeset.t()}
  def send_user_message(org_id, user, text) do
    attrs = %{
      text: text,
      sender_type: "user",
      sender_name: user.email |> String.split("@") |> List.first(),
      organization_id: org_id,
      user_id: user.id
    }

    create_and_broadcast(attrs)
  end

  @doc "Send a message from an agent. Used by the REST chat endpoint and internal triggers."
  @spec send_agent_message(Ecto.UUID.t(), map(), String.t()) :: {:ok, message()} | {:error, Ecto.Changeset.t()}
  def send_agent_message(org_id, agent, text) do
    attrs = %{
      text: text,
      sender_type: "agent",
      sender_name: agent.name,
      organization_id: org_id,
      kite_agent_id: agent.id
    }

    create_and_broadcast(attrs)
  end

  @doc "Send a system message (trade activity, connection events, etc)."
  @spec send_system_message(Ecto.UUID.t(), String.t()) :: {:ok, message()} | {:error, Ecto.Changeset.t()}
  def send_system_message(org_id, text) do
    attrs = %{
      text: text,
      sender_type: "system",
      sender_name: "System",
      organization_id: org_id
    }

    create_and_broadcast(attrs)
  end

  @doc "Subscribe to chat messages for an org."
  def subscribe(org_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(org_id))
  end

  @doc "Unsubscribe from chat messages for an org."
  def unsubscribe(org_id) do
    Phoenix.PubSub.unsubscribe(@pubsub, topic(org_id))
  end

  defp create_and_broadcast(attrs) do
    case %ChatMessage{} |> ChatMessage.changeset(attrs) |> Repo.insert() do
      {:ok, message} ->
        Phoenix.PubSub.broadcast(@pubsub, topic(attrs.organization_id), {:chat_message, message})
        {:ok, message}

      error ->
        error
    end
  end

  defp topic(org_id), do: "chat:org:#{org_id}"
end
