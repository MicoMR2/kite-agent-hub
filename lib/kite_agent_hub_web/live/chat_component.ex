defmodule KiteAgentHubWeb.ChatComponent do
  @moduledoc """
  Floating chat popup LiveComponent for the dashboard.

  Displays messages from the current organization's chat stream and
  allows the logged-in user to send messages or invite agents to the
  conversation. All reads and writes are scoped to `:org_id` so
  chat is isolated per workspace.

  Required assigns:
    * `:org_id`  — current organization id
    * `:user`    — current user struct (for `send_user_message/3`)
    * `:agents`  — list of all org agents (for the invite panel)
    * `:agent`   — currently selected agent (optional, for backwards compat)
  """
  use KiteAgentHubWeb, :live_component

  require Logger
  alias KiteAgentHub.Chat

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:open, fn -> false end)
      |> assign_new(:show_invite, fn -> false end)
      |> assign_new(:messages, fn -> [] end)
      |> assign_new(:chat_input, fn -> "" end)
      |> assign_new(:subscribed, fn -> false end)
      |> assign_new(:agents, fn -> [] end)

    socket =
      if assigns[:org_id] && !socket.assigns.subscribed do
        messages = Chat.list_messages(assigns.org_id, limit: 50)
        Chat.subscribe(assigns.org_id)

        socket
        |> assign(:messages, messages)
        |> assign(:subscribed, true)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_event("toggle_chat", _params, socket) do
    {:noreply, assign(socket, open: !socket.assigns.open, show_invite: false)}
  end

  def handle_event("toggle_invite", _params, socket) do
    {:noreply, assign(socket, :show_invite, !socket.assigns.show_invite)}
  end

  def handle_event("send_message", %{"text" => text}, socket) do
    text = String.trim(text)

    if text != "" && socket.assigns[:org_id] && socket.assigns[:user] do
      case Chat.send_user_message(socket.assigns.org_id, socket.assigns.user, text) do
        {:ok, _msg} ->
          messages = Chat.list_messages(socket.assigns.org_id, limit: 50)
          {:noreply, socket |> assign(:chat_input, "") |> assign(:messages, messages)}

        {:error, reason} ->
          Logger.warning("Chat send failed: #{inspect(reason)}")
          {:noreply, assign(socket, :chat_input, "")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("invite_agent", %{"agent_id" => agent_id}, socket) do
    org_id = socket.assigns[:org_id]
    agents = socket.assigns[:agents] || []
    agent = Enum.find(agents, &(to_string(&1.id) == agent_id))

    if agent && org_id do
      Chat.send_system_message(
        org_id,
        "#{agent.name} (#{String.capitalize(agent.agent_type || "agent")}) has joined the conversation."
      )

      messages = Chat.list_messages(org_id, limit: 50)
      {:noreply, socket |> assign(:messages, messages) |> assign(:show_invite, false)}
    else
      {:noreply, assign(socket, :show_invite, false)}
    end
  end

  # Legacy single-agent connect kept for backwards compat
  def handle_event("connect_agent", _params, socket) do
    agent = socket.assigns[:agent]
    org_id = socket.assigns[:org_id]

    if agent && org_id do
      Chat.send_system_message(
        org_id,
        "#{agent.name} connected to chat. Agent is ready to receive instructions."
      )

      messages = Chat.list_messages(org_id, limit: 50)
      {:noreply, assign(socket, :messages, messages)}
    else
      {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div id="chat-popup" class="fixed bottom-4 right-4 z-40">
      <%!-- Toggle Button --%>
      <%= if !@open do %>
        <button
          phx-click="toggle_chat"
          phx-target={@myself}
          class="w-14 h-14 rounded-full bg-emerald-500 hover:bg-emerald-400 text-black flex items-center justify-center shadow-lg shadow-emerald-500/20 transition-all hover:scale-105"
        >
          <svg class="w-6 h-6" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"/></svg>
        </button>
      <% end %>

      <%!-- Chat Window --%>
      <%= if @open do %>
        <div class="w-96 rounded-2xl border border-white/10 bg-[#0a0a0f] shadow-2xl flex flex-col overflow-hidden">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-4 py-3 border-b border-white/10 bg-white/[0.02]">
            <div class="flex items-center gap-2">
              <span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span>
              <h3 class="text-xs font-black text-white uppercase tracking-widest">Agent Chat</h3>
            </div>
            <div class="flex items-center gap-2">
              <%!-- Invite Agents button --%>
              <%= if @agents != [] do %>
                <button
                  phx-click="toggle_invite"
                  phx-target={@myself}
                  class={[
                    "text-[10px] font-bold uppercase tracking-widest transition-colors flex items-center gap-1 px-2 py-1 rounded-lg border",
                    if(@show_invite,
                      do: "text-white border-white/20 bg-white/[0.08]",
                      else: "text-emerald-400 border-emerald-500/20 bg-emerald-500/5 hover:bg-emerald-500/10"
                    )
                  ]}
                >
                  <svg class="w-3 h-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="2">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M18 9v3m0 0v3m0-3h3m-3 0h-3m-2-5a4 4 0 11-8 0 4 4 0 018 0zM3 20a6 6 0 0112 0v1H3v-1z"/>
                  </svg>
                  Invite Agents
                </button>
              <% end %>
              <button phx-click="toggle_chat" phx-target={@myself} class="text-gray-500 hover:text-white transition-colors">
                <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
              </button>
            </div>
          </div>

          <%!-- Invite Panel --%>
          <%= if @show_invite do %>
            <div class="border-b border-white/10 bg-white/[0.01] px-4 py-3">
              <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-2">Select an agent to invite</p>
              <div class="space-y-1.5 max-h-48 overflow-y-auto">
                <%= for agent <- @agents do %>
                  <button
                    phx-click="invite_agent"
                    phx-value-agent_id={agent.id}
                    phx-target={@myself}
                    class="w-full flex items-center justify-between gap-3 px-3 py-2 rounded-xl border border-white/5 bg-white/[0.01] hover:border-white/20 hover:bg-white/[0.05] transition-all text-left group"
                  >
                    <div class="flex items-center gap-2 min-w-0">
                      <span class={[
                        "w-1.5 h-1.5 rounded-full shrink-0",
                        case agent.status do
                          "active" -> "bg-emerald-400"
                          "pending" -> "bg-yellow-400"
                          _ -> "bg-gray-500"
                        end
                      ]}></span>
                      <span class="text-xs font-semibold text-white truncate">{agent.name}</span>
                      <span class={[
                        "text-[9px] font-bold uppercase tracking-widest px-1.5 py-0.5 rounded border shrink-0",
                        case agent.agent_type do
                          "trading" -> "text-white border-white/15 bg-white/5"
                          "research" -> "text-blue-400 border-blue-500/20 bg-blue-500/5"
                          _ -> "text-purple-400 border-purple-500/20 bg-purple-500/5"
                        end
                      ]}>
                        {String.capitalize(agent.agent_type || "agent")}
                      </span>
                    </div>
                    <span class="text-[10px] text-emerald-400 font-bold uppercase tracking-widest opacity-0 group-hover:opacity-100 transition-opacity shrink-0">
                      Invite →
                    </span>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>

          <%!-- Messages --%>
          <div id="chat-messages" class="h-[380px] overflow-y-auto px-4 py-3 space-y-3" phx-hook="ScrollBottom">
            <%= if @messages == [] do %>
              <div class="text-center mt-10 space-y-2">
                <p class="text-gray-600 text-xs">No messages yet.</p>
                <p class="text-gray-700 text-[10px]">Use "Invite Agents" to bring agents into this chat.</p>
              </div>
            <% end %>
            <%= for msg <- @messages do %>
              <% agent_type = agent_type_for_message(msg, @agents) %>
              <div class={["flex flex-col min-w-0", msg.sender_type == "user" && "items-end"]}>
                <span class={[
                  "text-[10px] font-bold uppercase tracking-widest mb-0.5",
                  label_color(msg.sender_type, agent_type)
                ]}>{msg.sender_name}</span>
                <div class={[
                  "max-w-[85%] min-w-0 rounded-xl px-3 py-2 text-xs leading-relaxed break-words overflow-hidden",
                  bubble_classes(msg.sender_type, agent_type)
                ]}>
                  {msg.text}
                </div>
                <%= if msg.inserted_at do %>
                  <span
                    id={"chat-msg-time-#{msg.id}"}
                    phx-hook="LocalTime"
                    data-iso={DateTime.to_iso8601(msg.inserted_at)}
                    data-format="time"
                    class="text-[9px] text-gray-700 font-mono mt-0.5"
                  >
                    {Calendar.strftime(msg.inserted_at, "%H:%M")}
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Input --%>
          <form phx-submit="send_message" phx-target={@myself} class="border-t border-white/10 px-3 py-3 flex gap-2">
            <input
              type="text"
              name="text"
              value={@chat_input}
              placeholder="Message your agents..."
              autocomplete="off"
              class="flex-1 bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-xs text-white placeholder-gray-600 focus:outline-none focus:border-white/20"
            />
            <button
              type="submit"
              class="px-3 py-2 rounded-xl bg-emerald-500 hover:bg-emerald-400 text-black text-xs font-black uppercase tracking-widest transition-colors"
            >
              Send
            </button>
          </form>
        </div>
      <% end %>
    </div>
    """
  end

  # Look up the agent_type for a given chat message. Prefers the
  # FK (`kite_agent_id`), then falls back to matching by sender_name
  # so older messages written before the FK was populated still color
  # correctly. Returns nil for user/system messages or unknown agents.
  defp agent_type_for_message(%{sender_type: "agent"} = msg, agents) when is_list(agents) do
    by_id =
      case Map.get(msg, :kite_agent_id) do
        nil -> nil
        id -> Enum.find(agents, &(&1.id == id))
      end

    agent =
      by_id ||
        Enum.find(agents, fn a -> a.name == msg.sender_name end)

    agent && (agent.agent_type || "trading")
  end

  defp agent_type_for_message(_msg, _agents), do: nil

  defp label_color("user", _), do: "text-orange-400"
  defp label_color("system", _), do: "text-gray-600"
  defp label_color("agent", "research"), do: "text-blue-400"
  defp label_color("agent", "conversational"), do: "text-purple-400"
  defp label_color("agent", _), do: "text-emerald-400"
  defp label_color(_, _), do: "text-gray-400"

  defp bubble_classes("user", _),
    do: "bg-orange-500/15 border border-orange-500/30 text-white"

  defp bubble_classes("system", _),
    do: "bg-white/[0.02] border border-white/5 text-gray-500 italic"

  defp bubble_classes("agent", "research"),
    do: "bg-blue-500/10 border border-blue-500/20 text-gray-200"

  defp bubble_classes("agent", "conversational"),
    do: "bg-purple-500/10 border border-purple-500/20 text-gray-200"

  defp bubble_classes("agent", _),
    do: "bg-emerald-500/10 border border-emerald-500/20 text-gray-200"

  defp bubble_classes(_, _),
    do: "bg-white/[0.02] border border-white/5 text-gray-400"
end
