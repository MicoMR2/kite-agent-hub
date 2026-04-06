defmodule KiteAgentHubWeb.ChatComponent do
  use KiteAgentHubWeb, :live_component

  alias KiteAgentHub.Chat

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:open, fn -> false end)
      |> assign_new(:messages, fn -> [] end)
      |> assign_new(:chat_input, fn -> "" end)
      |> assign_new(:subscribed, fn -> false end)

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
    {:noreply, assign(socket, :open, !socket.assigns.open)}
  end

  def handle_event("send_message", %{"text" => text}, socket) do
    text = String.trim(text)

    if text != "" && socket.assigns.org_id && socket.assigns.user do
      Chat.send_user_message(socket.assigns.org_id, socket.assigns.user, text)
    end

    {:noreply, assign(socket, :chat_input, "")}
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
        <div class="w-96 h-[500px] rounded-2xl border border-white/10 bg-[#0a0a0f] shadow-2xl flex flex-col overflow-hidden">
          <%!-- Header --%>
          <div class="flex items-center justify-between px-4 py-3 border-b border-white/10 bg-white/[0.02]">
            <div class="flex items-center gap-2">
              <span class="w-2 h-2 rounded-full bg-emerald-400 animate-pulse"></span>
              <h3 class="text-xs font-black text-white uppercase tracking-widest">Agent Chat</h3>
            </div>
            <button phx-click="toggle_chat" phx-target={@myself} class="text-gray-500 hover:text-white transition-colors">
              <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7"/></svg>
            </button>
          </div>

          <%!-- Messages --%>
          <div id="chat-messages" class="flex-1 overflow-y-auto px-4 py-3 space-y-3" phx-hook="ScrollBottom">
            <%= if @messages == [] do %>
              <p class="text-center text-gray-600 text-xs mt-10">No messages yet. Say hello to your agent!</p>
            <% end %>
            <%= for msg <- @messages do %>
              <div class={["flex flex-col", msg.sender_type == "user" && "items-end"]}>
                <span class={[
                  "text-[10px] font-bold uppercase tracking-widest mb-0.5",
                  msg.sender_type == "user" && "text-blue-400",
                  msg.sender_type == "agent" && "text-emerald-400",
                  msg.sender_type == "system" && "text-gray-600"
                ]}>{msg.sender_name}</span>
                <div class={[
                  "max-w-[85%] rounded-xl px-3 py-2 text-xs leading-relaxed",
                  msg.sender_type == "user" && "bg-blue-500/10 border border-blue-500/20 text-gray-200",
                  msg.sender_type == "agent" && "bg-emerald-500/10 border border-emerald-500/20 text-gray-200",
                  msg.sender_type == "system" && "bg-white/[0.02] border border-white/5 text-gray-500 italic"
                ]}>
                  {msg.text}
                </div>
                <span class="text-[9px] text-gray-700 font-mono mt-0.5">
                  {if msg.inserted_at, do: Calendar.strftime(msg.inserted_at, "%H:%M"), else: ""}
                </span>
              </div>
            <% end %>
          </div>

          <%!-- Input --%>
          <form phx-submit="send_message" phx-target={@myself} class="border-t border-white/10 px-3 py-3 flex gap-2">
            <input
              type="text"
              name="text"
              value={@chat_input}
              placeholder="Message your agent..."
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
end
