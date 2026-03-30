defmodule KiteAgentHubWeb.TradesLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Trading, Orgs}

  @page_size 25

  @impl true
  def mount(_params, _session, socket) do
    org = Orgs.get_org_for_user(socket.assigns.current_scope.user.id)
    agents = Trading.list_agents(org.id)

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:agents, agents)
     |> assign(:selected_agent, nil)
     |> assign(:trades, [])
     |> assign(:status_filter, "all")
     |> assign(:page, 1)
     |> assign(:has_more, false)}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id} = params, _uri, socket) do
    agent = Trading.get_agent!(agent_id)
    status = params["status"] || "all"

    if socket.assigns.selected_agent?.id != agent_id do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent_id}")
      end
    end

    trades = load_trades(agent_id, status, 1)

    {:noreply,
     socket
     |> assign(:selected_agent, agent)
     |> assign(:status_filter, status)
     |> assign(:trades, trades)
     |> assign(:page, 1)
     |> assign(:has_more, length(trades) == @page_size)}
  end

  def handle_params(_params, _uri, socket) do
    # No agent selected — pick first if available
    case socket.assigns.agents do
      [first | _] ->
        {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{first.id}")}

      [] ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    agent_id = socket.assigns.selected_agent.id

    {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{agent_id}&status=#{status}")}
  end

  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    agent_id = socket.assigns.selected_agent.id
    status = socket.assigns.status_filter

    new_trades = load_trades(agent_id, status, next_page)

    {:noreply,
     socket
     |> assign(:trades, socket.assigns.trades ++ new_trades)
     |> assign(:page, next_page)
     |> assign(:has_more, length(new_trades) == @page_size)}
  end

  def handle_event("select_agent", %{"id" => agent_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/trades?agent_id=#{agent_id}")}
  end

  @impl true
  def handle_info({:trade_created, trade}, socket) do
    if trade.kite_agent_id == socket.assigns.selected_agent?.id do
      {:noreply, assign(socket, :trades, [trade | socket.assigns.trades])}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:trade_updated, updated}, socket) do
    trades =
      Enum.map(socket.assigns.trades, fn t ->
        if t.id == updated.id, do: updated, else: t
      end)

    {:noreply, assign(socket, :trades, trades)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp load_trades(agent_id, "all", page) do
    Trading.list_trades(agent_id, limit: @page_size, offset: (page - 1) * @page_size)
  end

  defp load_trades(agent_id, status, page) do
    Trading.list_trades(agent_id,
      status: status,
      limit: @page_size,
      offset: (page - 1) * @page_size
    )
  end

  defp status_badge("open"), do: "bg-blue-100 text-blue-800"
  defp status_badge("settled"), do: "bg-green-100 text-green-800"
  defp status_badge("failed"), do: "bg-red-100 text-red-800"
  defp status_badge("cancelled"), do: "bg-gray-100 text-gray-600"
  defp status_badge(_), do: "bg-gray-100 text-gray-600"

  defp pnl_class(nil), do: "text-gray-400"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :gt -> "text-green-600 font-semibold"
      :lt -> "text-red-500 font-semibold"
      _ -> "text-gray-500"
    end
  end

  defp format_pnl(nil), do: "—"

  defp format_pnl(pnl) do
    val = Decimal.to_float(pnl)

    if val >= 0,
      do: "+$#{:erlang.float_to_binary(val, decimals: 2)}",
      else: "-$#{:erlang.float_to_binary(abs(val), decimals: 2)}"
  end

  defp format_notional(nil), do: "—"
  defp format_notional(n), do: "$#{Decimal.round(n, 2)}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-950 text-white p-6">
      <div class="max-w-7xl mx-auto">
        <!-- Header -->
        <div class="flex items-center justify-between mb-6">
          <div>
            <h1 class="text-2xl font-bold tracking-tight">Trade History</h1>
            <p class="text-gray-400 text-sm mt-1">All trades executed by your agents</p>
          </div>
          <.link navigate={~p"/dashboard"} class="text-sm text-gray-400 hover:text-white transition">
            ← Dashboard
          </.link>
        </div>

        <div class="grid grid-cols-12 gap-6">
          <!-- Agent Sidebar -->
          <div class="col-span-3">
            <div class="bg-gray-900 rounded-xl border border-gray-800 p-4">
              <h2 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-3">
                Agents
              </h2>
              <div class="space-y-1">
                <%= for agent <- @agents do %>
                  <button
                    phx-click="select_agent"
                    phx-value-id={agent.id}
                    class={"w-full text-left px-3 py-2 rounded-lg text-sm transition #{if @selected_agent?.id == agent.id, do: "bg-indigo-600 text-white", else: "text-gray-300 hover:bg-gray-800"}"}
                  >
                    <div class="font-medium truncate">{agent.name}</div>
                    <div class={"text-xs mt-0.5 #{if @selected_agent?.id == agent.id, do: "text-indigo-200", else: "text-gray-500"}"}>
                      {agent.status}
                    </div>
                  </button>
                <% end %>
              </div>
            </div>
          </div>
          
    <!-- Trade Table -->
          <div class="col-span-9">
            <!-- Filter tabs -->
            <div class="flex gap-2 mb-4">
              <%= for {label, val} <- [{"All", "all"}, {"Open", "open"}, {"Settled", "settled"}, {"Failed", "failed"}] do %>
                <button
                  phx-click="filter"
                  phx-value-status={val}
                  class={"px-4 py-1.5 rounded-full text-sm font-medium transition #{if @status_filter == val, do: "bg-indigo-600 text-white", else: "bg-gray-800 text-gray-400 hover:text-white"}"}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <div class="bg-gray-900 rounded-xl border border-gray-800 overflow-hidden">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-gray-800">
                    <th class="text-left px-4 py-3 text-gray-400 font-medium">Market</th>
                    <th class="text-left px-4 py-3 text-gray-400 font-medium">Action</th>
                    <th class="text-right px-4 py-3 text-gray-400 font-medium">Contracts</th>
                    <th class="text-right px-4 py-3 text-gray-400 font-medium">Fill Price</th>
                    <th class="text-right px-4 py-3 text-gray-400 font-medium">Notional</th>
                    <th class="text-right px-4 py-3 text-gray-400 font-medium">P&L</th>
                    <th class="text-center px-4 py-3 text-gray-400 font-medium">Status</th>
                    <th class="text-left px-4 py-3 text-gray-400 font-medium">Time</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-800">
                  <%= if @trades == [] do %>
                    <tr>
                      <td colspan="8" class="px-4 py-12 text-center text-gray-500">
                        No trades found.
                      </td>
                    </tr>
                  <% else %>
                    <%= for trade <- @trades do %>
                      <tr class="hover:bg-gray-800/50 transition">
                        <td class="px-4 py-3 font-mono text-xs text-gray-200">{trade.market}</td>
                        <td class="px-4 py-3">
                          <span class={"font-medium #{if trade.action == "buy", do: "text-green-400", else: "text-red-400"}"}>
                            {String.upcase(trade.action)}
                          </span>
                          <span class="text-gray-500 ml-1 text-xs">{trade.side}</span>
                        </td>
                        <td class="px-4 py-3 text-right tabular-nums">{trade.contracts}</td>
                        <td class="px-4 py-3 text-right tabular-nums font-mono text-xs">
                          ${trade.fill_price}
                        </td>
                        <td class="px-4 py-3 text-right tabular-nums text-gray-300">
                          {format_notional(trade.notional_usd)}
                        </td>
                        <td class={"px-4 py-3 text-right tabular-nums #{pnl_class(trade.realized_pnl)}"}>
                          {format_pnl(trade.realized_pnl)}
                        </td>
                        <td class="px-4 py-3 text-center">
                          <span class={"px-2 py-0.5 rounded-full text-xs font-medium #{status_badge(trade.status)}"}>
                            {trade.status}
                          </span>
                        </td>
                        <td class="px-4 py-3 text-xs text-gray-500 whitespace-nowrap">
                          {Calendar.strftime(trade.inserted_at, "%b %d %H:%M")}
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>

              <%= if @has_more do %>
                <div class="px-4 py-3 border-t border-gray-800 text-center">
                  <button
                    phx-click="load_more"
                    class="text-sm text-indigo-400 hover:text-indigo-300 transition"
                  >
                    Load more →
                  </button>
                </div>
              <% end %>
            </div>

            <%= if trade = Enum.find(@trades, &(&1.reason)) do %>
              <div class="mt-4 p-4 bg-gray-900 rounded-xl border border-gray-800">
                <h3 class="text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                  Latest Signal Reason
                </h3>
                <p class="text-sm text-gray-300">{trade.reason}</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
