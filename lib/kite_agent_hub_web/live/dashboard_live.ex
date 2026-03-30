defmodule KiteAgentHubWeb.DashboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    {agents, trades} =
      if org do
        agents = Trading.list_agents(org.id)
        selected = List.first(agents)
        trades = if selected, do: Trading.list_trades(selected.id, limit: 20), else: []
        {agents, trades}
      else
        {[], []}
      end

    selected_agent = List.first(agents)

    if connected?(socket) && selected_agent do
      Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{selected_agent.id}")
    end

    socket =
      socket
      |> assign(:organization, org)
      |> assign(:agents, agents)
      |> assign(:selected_agent, selected_agent)
      |> assign(:vault_form, to_form(%{"vault_address" => ""}, as: :vault))
      |> stream(:trades, trades)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    agent = Trading.get_agent!(agent_id)
    trades = Trading.list_trades(agent.id, limit: 20)

    if connected?(socket) do
      if socket.assigns.selected_agent do
        Phoenix.PubSub.unsubscribe(KiteAgentHub.PubSub, "agent:#{socket.assigns.selected_agent.id}")
      end
      Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent.id}")
    end

    {:noreply,
     socket
     |> assign(:selected_agent, agent)
     |> stream(:trades, trades, reset: true)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("activate_vault", %{"vault" => %{"vault_address" => vault_address}}, socket) do
    agent = socket.assigns.selected_agent
    vault_address = String.trim(vault_address)

    cond do
      is_nil(agent) ->
        {:noreply, put_flash(socket, :error, "No agent selected.")}

      not String.match?(vault_address, ~r/^0x[0-9a-fA-F]{40}$/) ->
        {:noreply, put_flash(socket, :error, "Invalid vault address — must be a 0x EVM address.")}

      true ->
        case Trading.activate_agent(agent, vault_address) do
          {:ok, updated_agent} ->
            agents = Enum.map(socket.assigns.agents, fn a ->
              if a.id == updated_agent.id, do: updated_agent, else: a
            end)

            {:noreply,
             socket
             |> assign(:selected_agent, updated_agent)
             |> assign(:agents, agents)
             |> put_flash(:info, "Agent activated! Vault is live on Kite chain.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to activate agent. Check the vault address.")}
        end
    end
  end

  @impl true
  def handle_info({:trade_updated, trade}, socket) do
    {:noreply, stream_insert(socket, :trades, trade, at: 0)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-gray-950 text-gray-100">
        <!-- Header -->
        <div class="border-b border-gray-800 px-6 py-4">
          <div class="max-w-7xl mx-auto flex items-center justify-between">
            <div>
              <h1 class="text-xl font-bold tracking-tight text-white">Kite Agent Hub</h1>
              <p class="text-xs text-gray-500 mt-0.5">
                {if @organization, do: @organization.name, else: "No workspace"}
              </p>
            </div>
            <div class="flex items-center gap-3">
              <%= if @selected_agent do %>
                <span class={[
                  "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-medium",
                  @selected_agent.status == "active" && "bg-emerald-500/15 text-emerald-400",
                  @selected_agent.status == "paused" && "bg-yellow-500/15 text-yellow-400",
                  @selected_agent.status == "pending" && "bg-gray-500/15 text-gray-400",
                  @selected_agent.status == "error" && "bg-red-500/15 text-red-400"
                ]}>
                  <span class={[
                    "w-1.5 h-1.5 rounded-full",
                    @selected_agent.status == "active" && "bg-emerald-400 animate-pulse",
                    @selected_agent.status == "paused" && "bg-yellow-400",
                    @selected_agent.status == "pending" && "bg-gray-400",
                    @selected_agent.status == "error" && "bg-red-400"
                  ]}></span>
                  {String.capitalize(@selected_agent.status)}
                </span>
              <% end %>
              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> New Agent
              </.link>
            </div>
          </div>
        </div>

        <div class="max-w-7xl mx-auto px-6 py-6 grid grid-cols-12 gap-6">
          <!-- Sidebar: Agent List -->
          <div class="col-span-3">
            <h2 class="text-xs font-semibold text-gray-500 uppercase tracking-wider mb-3">Your Agents</h2>
            <%= if @agents == [] do %>
              <div class="rounded-xl border border-dashed border-gray-700 p-6 text-center">
                <p class="text-sm text-gray-500">No agents yet.</p>
                <.link navigate={~p"/agents/new"} class="mt-3 inline-block text-xs text-violet-400 hover:text-violet-300">
                  Onboard your first agent →
                </.link>
              </div>
            <% else %>
              <div class="space-y-2">
                <%= for agent <- @agents do %>
                  <.link
                    patch={~p"/dashboard?agent_id=#{agent.id}"}
                    class={[
                      "block rounded-xl border px-4 py-3 transition-all",
                      @selected_agent && @selected_agent.id == agent.id &&
                        "border-violet-500/50 bg-violet-500/10",
                      (!@selected_agent || @selected_agent.id != agent.id) &&
                        "border-gray-800 bg-gray-900 hover:border-gray-700"
                    ]}
                  >
                    <div class="flex items-center justify-between">
                      <span class="text-sm font-medium text-white truncate">{agent.name}</span>
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0",
                        agent.status == "active" && "bg-emerald-400",
                        agent.status == "paused" && "bg-yellow-400",
                        agent.status == "pending" && "bg-gray-500",
                        agent.status == "error" && "bg-red-400"
                      ]}></span>
                    </div>
                    <p class="text-xs text-gray-500 mt-0.5 font-mono truncate">
                      {String.slice(agent.wallet_address, 0, 10)}…
                    </p>
                  </.link>
                <% end %>
              </div>
            <% end %>
          </div>

          <!-- Main: Agent Detail + Trade Feed -->
          <div class="col-span-9 space-y-6">
            <%= if @selected_agent do %>
              <!-- Agent Stats -->
              <div class="grid grid-cols-4 gap-4">
                <div class="rounded-xl bg-gray-900 border border-gray-800 px-4 py-3">
                  <p class="text-xs text-gray-500">Daily Limit</p>
                  <p class="text-lg font-semibold text-white mt-1">${@selected_agent.daily_limit_usd}K</p>
                </div>
                <div class="rounded-xl bg-gray-900 border border-gray-800 px-4 py-3">
                  <p class="text-xs text-gray-500">Per Trade</p>
                  <p class="text-lg font-semibold text-white mt-1">${@selected_agent.per_trade_limit_usd}</p>
                </div>
                <div class="rounded-xl bg-gray-900 border border-gray-800 px-4 py-3">
                  <p class="text-xs text-gray-500">Max Positions</p>
                  <p class="text-lg font-semibold text-white mt-1">{@selected_agent.max_open_positions}</p>
                </div>
                <div class="rounded-xl bg-gray-900 border border-gray-800 px-4 py-3">
                  <p class="text-xs text-gray-500">Vault</p>
                  <p class="text-xs font-mono text-violet-400 mt-1 truncate">
                    {if @selected_agent.vault_address,
                      do: String.slice(@selected_agent.vault_address, 0, 14) <> "…",
                      else: "Not deployed"}
                  </p>
                </div>
              </div>

              <!-- Vault Activation Banner -->
              <%= if @selected_agent.status == "pending" do %>
                <div class="rounded-xl border border-amber-500/30 bg-amber-500/5 p-5">
                  <div class="flex items-start gap-4">
                    <div class="h-9 w-9 rounded-lg bg-amber-500/15 flex items-center justify-center shrink-0">
                      <.icon name="hero-bolt" class="w-5 h-5 text-amber-400" />
                    </div>
                    <div class="flex-1 min-w-0">
                      <h3 class="text-sm font-semibold text-amber-300 mb-1">Activate your vault</h3>
                      <p class="text-xs text-amber-400/70 mb-4">
                        Run <code class="bg-gray-800 px-1.5 py-0.5 rounded text-amber-300">python scripts/agent_onboard.py --private-key YOUR_KEY</code> to deploy the vault contract, then paste the address below.
                      </p>
                      <.form for={@vault_form} phx-submit="activate_vault" class="flex gap-3">
                        <input
                          type="text"
                          name="vault[vault_address]"
                          placeholder="0x vault address"
                          class="flex-1 rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white font-mono text-sm placeholder-gray-500 focus:border-amber-500 focus:outline-none"
                        />
                        <button
                          type="submit"
                          phx-disable-with="Activating..."
                          class="px-4 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-gray-900 font-semibold text-sm transition-colors whitespace-nowrap"
                        >
                          Activate
                        </button>
                      </.form>
                    </div>
                  </div>
                </div>
              <% end %>

              <!-- Live Trade Feed -->
              <div class="rounded-xl bg-gray-900 border border-gray-800">
                <div class="flex items-center justify-between px-5 py-4 border-b border-gray-800">
                  <h3 class="text-sm font-semibold text-white">Live Trade Feed</h3>
                  <span class="flex items-center gap-1.5 text-xs text-emerald-400">
                    <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                    Live
                  </span>
                </div>

                <div id="trades" phx-update="stream" class="divide-y divide-gray-800">
                  <div class="hidden only:flex items-center justify-center py-12 text-gray-500 text-sm">
                    No trades yet — agent is standing by
                  </div>
                  <%= for {id, trade} <- @streams.trades do %>
                    <div id={id} class="flex items-center gap-4 px-5 py-3 hover:bg-gray-800/50 transition-colors">
                      <span class={[
                        "inline-flex items-center px-2 py-0.5 rounded text-xs font-bold uppercase",
                        trade.action == "buy" && "bg-emerald-500/15 text-emerald-400",
                        trade.action == "sell" && "bg-red-500/15 text-red-400"
                      ]}>
                        {trade.action} {trade.side}
                      </span>
                      <span class="text-sm font-medium text-white flex-1">{trade.market}</span>
                      <span class="text-xs text-gray-400">{trade.contracts}x @ ${trade.fill_price}</span>
                      <span class={[
                        "text-xs px-2 py-0.5 rounded-full",
                        trade.status == "open" && "bg-blue-500/15 text-blue-400",
                        trade.status == "settled" && "bg-gray-500/15 text-gray-400",
                        trade.status == "cancelled" && "bg-yellow-500/15 text-yellow-400",
                        trade.status == "failed" && "bg-red-500/15 text-red-400"
                      ]}>
                        {trade.status}
                      </span>
                      <%= if trade.realized_pnl do %>
                        <span class={[
                          "text-xs font-medium",
                          Decimal.gt?(trade.realized_pnl, 0) && "text-emerald-400",
                          Decimal.lt?(trade.realized_pnl, 0) && "text-red-400",
                          Decimal.eq?(trade.realized_pnl, 0) && "text-gray-400"
                        ]}>
                          {if Decimal.gt?(trade.realized_pnl, 0), do: "+"}${trade.realized_pnl}
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% else %>
              <div class="rounded-xl border border-dashed border-gray-700 p-12 text-center">
                <div class="w-12 h-12 rounded-full bg-violet-500/10 flex items-center justify-center mx-auto mb-4">
                  <.icon name="hero-cpu-chip" class="w-6 h-6 text-violet-400" />
                </div>
                <h3 class="text-lg font-semibold text-white mb-2">No agent selected</h3>
                <p class="text-sm text-gray-500 mb-6">Onboard an agent to start trading on Kite chain.</p>
                <.link
                  navigate={~p"/agents/new"}
                  class="inline-flex items-center gap-2 px-4 py-2 rounded-lg bg-violet-600 hover:bg-violet-500 text-white text-sm font-medium transition-colors"
                >
                  <.icon name="hero-plus" class="w-4 h-4" /> Onboard Agent
                </.link>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
