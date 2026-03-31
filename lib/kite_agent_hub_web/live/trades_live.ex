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

  defp status_classes("open"), do: "bg-blue-500/10 text-blue-400 ring-1 ring-blue-500/20"
  defp status_classes("settled"), do: "bg-emerald-500/10 text-emerald-400 ring-1 ring-emerald-500/20"
  defp status_classes("failed"), do: "bg-red-500/10 text-red-400 ring-1 ring-red-500/20"
  defp status_classes("cancelled"), do: "bg-gray-500/10 text-gray-400 ring-1 ring-gray-500/20"
  defp status_classes(_), do: "bg-gray-500/10 text-gray-500"

  defp pnl_class(nil), do: "text-gray-600"

  defp pnl_class(pnl) do
    case Decimal.compare(pnl, Decimal.new(0)) do
      :gt -> "text-emerald-400 font-bold"
      :lt -> "text-red-400 font-bold"
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
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-gray-950 text-gray-100">
        <%!-- Nav --%>
        <div class="border-b border-white/[0.10] bg-gray-950/80 backdrop-blur-sm sticky top-0 z-10 px-6 py-3">
          <div class="max-w-7xl mx-auto flex items-center justify-between">
            <div class="flex items-center gap-3">
              <.link
                navigate={~p"/dashboard"}
                class="flex items-center gap-1.5 text-xs text-gray-500 hover:text-gray-300 transition-colors"
              >
                <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
              </.link>
              <span class="text-gray-700">/</span>
              <h1 class="text-sm font-bold text-white">Trade History</h1>
            </div>
            <div class="flex gap-1.5">
              <%= for {label, val} <- [{"All", "all"}, {"Open", "open"}, {"Settled", "settled"}, {"Failed", "failed"}] do %>
                <button
                  phx-click="filter"
                  phx-value-status={val}
                  class={[
                    "px-3 py-1 rounded-lg text-xs font-semibold transition-all",
                    @status_filter == val &&
                      "bg-violet-500/20 text-violet-300 ring-1 ring-violet-500/30",
                    @status_filter != val && "text-gray-500 hover:text-gray-300"
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>
          </div>
        </div>

        <div class="max-w-7xl mx-auto px-6 py-6 grid grid-cols-12 gap-5">
          <%!-- Agent Sidebar --%>
          <div class="col-span-3 space-y-2">
            <h2 class="text-xs font-bold text-gray-600 uppercase tracking-widest mb-3">
              Agents
            </h2>
            <%= for agent <- @agents do %>
              <button
                phx-click="select_agent"
                phx-value-id={agent.id}
                class={[
                  "w-full text-left px-4 py-3 rounded-xl ring-1 transition-all",
                  @selected_agent?.id == agent.id &&
                    "ring-violet-500/40 bg-violet-500/10",
                  @selected_agent?.id != agent.id &&
                    "ring-white/[0.12] bg-gray-900/60 hover:ring-white/[0.20]"
                ]}
              >
                <div class="flex items-center justify-between gap-2">
                  <span class="text-sm font-semibold text-white truncate">{agent.name}</span>
                  <span class={[
                    "w-2 h-2 rounded-full shrink-0",
                    agent.status == "active" && "bg-emerald-400",
                    agent.status == "paused" && "bg-yellow-400",
                    agent.status == "pending" && "bg-gray-500",
                    agent.status == "error" && "bg-red-400"
                  ]}>
                  </span>
                </div>
                <p class="text-xs text-gray-600 mt-0.5">{String.capitalize(agent.status)}</p>
              </button>
            <% end %>
          </div>

          <%!-- Trade Table --%>
          <div class="col-span-9">
            <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/[0.12] overflow-hidden">
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-white/[0.10]">
                    <th class="text-left px-5 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Market
                    </th>
                    <th class="text-left px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Action
                    </th>
                    <th class="text-right px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Qty
                    </th>
                    <th class="text-right px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Fill
                    </th>
                    <th class="text-right px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Notional
                    </th>
                    <th class="text-right px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      P&L
                    </th>
                    <th class="text-center px-4 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Status
                    </th>
                    <th class="text-right px-5 py-3.5 text-xs font-bold text-gray-500 uppercase tracking-wider">
                      Time
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @trades == [] do %>
                    <tr>
                      <td colspan="8" class="px-5 py-16 text-center">
                        <div class="flex flex-col items-center gap-3">
                          <div class="w-10 h-10 rounded-xl bg-gray-800 flex items-center justify-center">
                            <.icon
                              name="hero-arrow-trending-up"
                              class="w-5 h-5 text-gray-600"
                            />
                          </div>
                          <p class="text-sm text-gray-600">No trades yet</p>
                        </div>
                      </td>
                    </tr>
                  <% else %>
                    <%= for trade <- @trades do %>
                      <tr class="border-b border-white/[0.06] hover:bg-white/[0.02] transition-colors">
                        <td class="px-5 py-3.5 font-mono text-xs text-gray-300 font-medium">
                          {trade.market}
                        </td>
                        <td class="px-4 py-3.5">
                          <span class={[
                            "inline-flex px-2 py-0.5 rounded text-xs font-black uppercase",
                            trade.action == "buy" && "bg-emerald-500/10 text-emerald-400",
                            trade.action == "sell" && "bg-red-500/10 text-red-400"
                          ]}>
                            {trade.action}
                          </span>
                        </td>
                        <td class="px-4 py-3.5 text-right tabular-nums text-gray-300 text-xs">
                          {trade.contracts}
                        </td>
                        <td class="px-4 py-3.5 text-right tabular-nums font-mono text-xs text-gray-300">
                          ${trade.fill_price}
                        </td>
                        <td class="px-4 py-3.5 text-right tabular-nums text-xs text-gray-400">
                          {format_notional(trade.notional_usd)}
                        </td>
                        <td class={"px-4 py-3.5 text-right tabular-nums text-sm #{pnl_class(trade.realized_pnl)}"}>
                          {format_pnl(trade.realized_pnl)}
                        </td>
                        <td class="px-4 py-3.5 text-center">
                          <span class={"px-2 py-0.5 rounded-lg text-xs font-semibold #{status_classes(trade.status)}"}>
                            {trade.status}
                          </span>
                        </td>
                        <td class="px-5 py-3.5 text-right text-xs text-gray-600 tabular-nums whitespace-nowrap font-mono">
                          {Calendar.strftime(trade.inserted_at, "%b %d %H:%M")}
                        </td>
                      </tr>
                    <% end %>
                  <% end %>
                </tbody>
              </table>

              <%= if @has_more do %>
                <div class="px-5 py-4 border-t border-white/[0.10] text-center">
                  <button
                    phx-click="load_more"
                    class="text-xs text-violet-400 hover:text-violet-300 font-semibold transition-colors"
                  >
                    Load more →
                  </button>
                </div>
              <% end %>
            </div>

            <%= if trade = Enum.find(@trades, &(&1.reason)) do %>
              <div class="mt-4 rounded-xl bg-gray-900/60 ring-1 ring-white/[0.12] p-4">
                <h3 class="text-xs font-bold text-gray-500 uppercase tracking-wider mb-2">
                  Latest Signal Reasoning
                </h3>
                <p class="text-sm text-gray-300 leading-relaxed">{trade.reason}</p>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
