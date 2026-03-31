defmodule KiteAgentHubWeb.DashboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}
  alias KiteAgentHub.Kite.RPC

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    {agents, trades, stats} =
      if org do
        agents = Trading.list_agents(org.id)
        selected = List.first(agents)
        trades = if selected, do: Trading.list_trades(selected.id, limit: 20), else: []
        stats = if selected, do: Trading.agent_pnl_stats(selected.id), else: nil
        {agents, trades, stats}
      else
        {[], [], nil}
      end

    selected_agent = List.first(agents)

    if connected?(socket) && selected_agent do
      Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{selected_agent.id}")
      fetch_chain_data(selected_agent)
    end

    socket =
      socket
      |> assign(:organization, org)
      |> assign(:agents, agents)
      |> assign(:selected_agent, selected_agent)
      |> assign(:pnl_stats, stats)
      |> assign(:wallet_balance_eth, nil)
      |> assign(:block_number, nil)
      |> assign(:vault_form, to_form(%{"vault_address" => ""}, as: :vault))
      |> stream(:trades, trades)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    agent = Trading.get_agent!(agent_id)
    trades = Trading.list_trades(agent.id, limit: 20)
    stats = Trading.agent_pnl_stats(agent.id)

    if connected?(socket) do
      if socket.assigns.selected_agent do
        Phoenix.PubSub.unsubscribe(
          KiteAgentHub.PubSub,
          "agent:#{socket.assigns.selected_agent.id}"
        )
      end

      Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{agent.id}")
      fetch_chain_data(agent)
    end

    {:noreply,
     socket
     |> assign(:selected_agent, agent)
     |> assign(:pnl_stats, stats)
     |> assign(:wallet_balance_eth, nil)
     |> assign(:block_number, nil)
     |> stream(:trades, trades, reset: true)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ── Events ────────────────────────────────────────────────────────────────────

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
            {:noreply,
             socket
             |> assign(:selected_agent, updated_agent)
             |> update(:agents, &replace_agent(&1, updated_agent))
             |> put_flash(:info, "Agent activated! Vault is live on Kite chain.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to activate agent.")}
        end
    end
  end

  def handle_event("pause_agent", _params, socket) do
    case Trading.pause_agent(socket.assigns.selected_agent) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:selected_agent, updated)
         |> update(:agents, &replace_agent(&1, updated))
         |> put_flash(:info, "Agent paused.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not pause agent.")}
    end
  end

  def handle_event("resume_agent", _params, socket) do
    case Trading.resume_agent(socket.assigns.selected_agent) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:selected_agent, updated)
         |> update(:agents, &replace_agent(&1, updated))
         |> put_flash(:info, "Agent resumed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not resume agent.")}
    end
  end

  # ── PubSub / async messages ───────────────────────────────────────────────────

  @impl true
  def handle_info({:trade_created, trade}, socket) do
    stats = Trading.agent_pnl_stats(trade.kite_agent_id)

    {:noreply,
     socket
     |> assign(:pnl_stats, stats)
     |> stream_insert(:trades, trade, at: 0)}
  end

  def handle_info({:trade_updated, trade}, socket) do
    stats = Trading.agent_pnl_stats(trade.kite_agent_id)

    {:noreply,
     socket
     |> assign(:pnl_stats, stats)
     |> stream_insert(:trades, trade)}
  end

  def handle_info({:agent_updated, agent}, socket) do
    {:noreply,
     socket
     |> assign(:selected_agent, agent)
     |> update(:agents, &replace_agent(&1, agent))}
  end

  # Async wallet balance from Task
  def handle_info({ref, {:wallet_balance, balance_wei}}, socket) do
    Process.demonitor(ref, [:flush])
    eth = wei_to_eth(balance_wei)
    {:noreply, assign(socket, :wallet_balance_eth, eth)}
  end

  # Async block number from Task
  def handle_info({ref, {:block_number, number}}, socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, :block_number, number)}
  end

  # Ignore Task :DOWN — chain data is non-critical
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket), do: {:noreply, socket}

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp fetch_chain_data(agent) do
    wallet = agent.wallet_address

    Task.async(fn ->
      case RPC.get_balance(wallet) do
        {:ok, wei} -> {:wallet_balance, wei}
        _ -> {:wallet_balance, nil}
      end
    end)

    Task.async(fn ->
      case RPC.block_number() do
        {:ok, n} -> {:block_number, n}
        _ -> {:block_number, nil}
      end
    end)
  end

  defp replace_agent(agents, updated) do
    Enum.map(agents, fn a -> if a.id == updated.id, do: updated, else: a end)
  end

  defp wei_to_eth(nil), do: nil

  defp wei_to_eth(wei) when is_integer(wei) do
    Float.round(wei / 1_000_000_000_000_000_000, 6)
  end

  defp pnl_color(nil), do: "text-gray-400"

  defp pnl_color(val) do
    cond do
      Decimal.gt?(val, 0) -> "text-emerald-400"
      Decimal.lt?(val, 0) -> "text-red-400"
      true -> "text-gray-400"
    end
  end

  defp win_rate(_win, 0), do: "—"

  defp win_rate(win, total) do
    pct = Float.round(win / total * 100, 1)
    "#{pct}%"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-gray-950 text-gray-100">
        <%!-- Top nav bar --%>
        <div class="border-b border-white/[0.10] bg-gray-950/80 backdrop-blur-sm sticky top-0 z-10 px-6 py-3">
          <div class="max-w-7xl mx-auto flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="h-8 w-8 rounded-lg bg-gradient-to-br from-violet-500 to-purple-600 flex items-center justify-center shadow-lg shadow-violet-500/25">
                <.icon name="hero-bolt" class="w-4 h-4 text-white" />
              </div>
              <div>
                <span class="text-sm font-bold text-white tracking-tight">Kite Agent Hub</span>
                <span class="text-gray-600 mx-2">·</span>
                <span class="text-xs text-gray-500">
                  {if @organization, do: @organization.name, else: "No workspace"}
                </span>
              </div>
            </div>
            <div class="flex items-center gap-4">
              <%= if @block_number do %>
                <div class="flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-emerald-500/10 ring-1 ring-emerald-500/20">
                  <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                  <span class="text-xs font-mono text-emerald-400">Block {@block_number}</span>
                </div>
              <% end %>
              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-1.5 px-3.5 py-1.5 rounded-lg bg-gradient-to-r from-violet-600 to-purple-600 hover:from-violet-500 hover:to-purple-500 text-white text-sm font-semibold transition-all shadow-lg shadow-violet-500/20 hover:shadow-violet-500/30"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> New Agent
              </.link>
            </div>
          </div>
        </div>

        <%= if @agents == [] do %>
          <%!-- ═══════════════ EMPTY STATE — first-time user ═══════════════ --%>
          <div class="max-w-4xl mx-auto px-6 py-20 text-center">
            <%!-- Hero --%>
            <div class="relative mb-12">
              <div class="absolute inset-0 flex items-center justify-center opacity-10">
                <div class="w-96 h-96 rounded-full bg-gradient-to-br from-violet-600 to-purple-600 blur-3xl"></div>
              </div>
              <div class="relative">
                <div class="w-20 h-20 rounded-2xl bg-gradient-to-br from-violet-500 to-purple-600 flex items-center justify-center mx-auto mb-6 shadow-2xl shadow-violet-500/30">
                  <.icon name="hero-cpu-chip" class="w-10 h-10 text-white" />
                </div>
                <h1 class="text-4xl font-black text-white mb-4 tracking-tight">
                  Autonomous AI Trading.<br />
                  <span class="bg-gradient-to-r from-violet-400 to-purple-400 bg-clip-text text-transparent">
                    On-Chain. Unstoppable.
                  </span>
                </h1>
                <p class="text-lg text-gray-400 max-w-xl mx-auto">
                  Deploy a trading agent powered by Claude AI. It reads market data, generates signals, and executes trades on Kite chain — around the clock, fully autonomous.
                </p>
              </div>
            </div>

            <%!-- Steps --%>
            <div class="grid grid-cols-3 gap-4 mb-10">
              <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/[0.12] p-6 text-left">
                <div class="w-10 h-10 rounded-xl bg-violet-500/15 flex items-center justify-center mb-4">
                  <span class="text-lg font-black text-violet-400">1</span>
                </div>
                <h3 class="text-sm font-bold text-white mb-2">Create an Agent</h3>
                <p class="text-xs text-gray-500 leading-relaxed">
                  Name your agent, set spending limits, and provide your Kite wallet address. Takes 30 seconds.
                </p>
              </div>
              <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/[0.12] p-6 text-left">
                <div class="w-10 h-10 rounded-xl bg-violet-500/15 flex items-center justify-center mb-4">
                  <span class="text-lg font-black text-violet-400">2</span>
                </div>
                <h3 class="text-sm font-bold text-white mb-2">Deploy a Vault</h3>
                <p class="text-xs text-gray-500 leading-relaxed">
                  Deploy the TradingAgentVault contract on Kite testnet and fund it from the faucet. Your keys never leave your machine.
                </p>
              </div>
              <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/[0.12] p-6 text-left">
                <div class="w-10 h-10 rounded-xl bg-emerald-500/15 flex items-center justify-center mb-4">
                  <span class="text-lg font-black text-emerald-400">3</span>
                </div>
                <h3 class="text-sm font-bold text-white mb-2">Watch It Trade</h3>
                <p class="text-xs text-gray-500 leading-relaxed">
                  Activate and the AgentRunner starts ticking. Claude Haiku generates signals. Trades execute and settle on-chain in real time.
                </p>
              </div>
            </div>

            <.link
              navigate={~p"/agents/new"}
              class="inline-flex items-center gap-2 px-8 py-4 rounded-xl bg-gradient-to-r from-violet-600 to-purple-600 hover:from-violet-500 hover:to-purple-500 text-white text-base font-bold transition-all shadow-2xl shadow-violet-500/30 hover:shadow-violet-500/40 hover:-translate-y-0.5 transform"
            >
              <.icon name="hero-bolt" class="w-5 h-5" /> Launch Your First Agent
            </.link>
            <p class="text-xs text-gray-600 mt-4">
              Running on Kite AI testnet · Chain ID 2368 · Powered by Claude
            </p>
          </div>
        <% else %>
          <%!-- ═══════════════ MAIN DASHBOARD ═══════════════ --%>
          <div class="max-w-7xl mx-auto px-6 py-6 grid grid-cols-12 gap-5">
            <%!-- ── Sidebar: Agent List ── --%>
            <div class="col-span-3 space-y-3">
              <div class="flex items-center justify-between mb-1">
                <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">Agents</h2>
                <span class="text-xs text-gray-600">{length(@agents)} total</span>
              </div>

              <%= for agent <- @agents do %>
                <.link
                  patch={~p"/dashboard?agent_id=#{agent.id}"}
                  class={[
                    "block rounded-xl p-4 transition-all ring-1 cursor-pointer",
                    @selected_agent && @selected_agent.id == agent.id &&
                      "ring-violet-500/40 bg-gradient-to-br from-violet-500/10 to-purple-500/5 shadow-lg shadow-violet-500/10",
                    (!@selected_agent || @selected_agent.id != agent.id) &&
                      "ring-white/[0.12] bg-gray-900/60 hover:ring-white/[0.20] hover:bg-gray-900"
                  ]}
                >
                  <div class="flex items-start justify-between gap-2 mb-2">
                    <span class="text-sm font-semibold text-white truncate leading-tight">
                      {agent.name}
                    </span>
                    <span class={[
                      "w-2 h-2 rounded-full shrink-0 mt-1",
                      agent.status == "active" && "bg-emerald-400 shadow-sm shadow-emerald-400/50",
                      agent.status == "paused" && "bg-yellow-400",
                      agent.status == "pending" && "bg-gray-500",
                      agent.status == "error" && "bg-red-400"
                    ]}>
                    </span>
                  </div>
                  <p class="text-xs text-gray-600 font-mono truncate">
                    {String.slice(agent.wallet_address || "", 0, 12)}…
                  </p>
                  <div class="mt-2 flex items-center gap-1.5">
                    <span class={[
                      "text-xs px-1.5 py-0.5 rounded font-medium",
                      agent.status == "active" && "bg-emerald-500/10 text-emerald-400",
                      agent.status == "paused" && "bg-yellow-500/10 text-yellow-400",
                      agent.status == "pending" && "bg-gray-500/10 text-gray-400",
                      agent.status == "error" && "bg-red-500/10 text-red-400"
                    ]}>
                      {String.capitalize(agent.status)}
                    </span>
                  </div>
                </.link>
              <% end %>

              <.link
                navigate={~p"/agents/new"}
                class="flex items-center justify-center gap-2 w-full rounded-xl py-3 ring-1 ring-dashed ring-white/10 text-gray-600 hover:text-gray-400 hover:ring-white/20 transition-all text-xs font-medium"
              >
                <.icon name="hero-plus" class="w-3.5 h-3.5" /> Add Agent
              </.link>
            </div>

            <%!-- ── Main Panel ── --%>
            <div class="col-span-9 space-y-4">
              <%= if @selected_agent do %>
                <%!-- Agent header --%>
                <div class="rounded-2xl bg-gradient-to-br from-gray-900 to-gray-900/50 ring-1 ring-white/[0.12] p-5">
                  <div class="flex items-start justify-between">
                    <div>
                      <div class="flex items-center gap-3 mb-1">
                        <h2 class="text-xl font-black text-white tracking-tight">
                          {@selected_agent.name}
                        </h2>
                        <span class={[
                          "inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-semibold",
                          @selected_agent.status == "active" &&
                            "bg-emerald-500/15 text-emerald-400 ring-1 ring-emerald-500/30",
                          @selected_agent.status == "paused" &&
                            "bg-yellow-500/15 text-yellow-400 ring-1 ring-yellow-500/30",
                          @selected_agent.status == "pending" &&
                            "bg-amber-500/15 text-amber-400 ring-1 ring-amber-500/30",
                          @selected_agent.status == "error" &&
                            "bg-red-500/15 text-red-400 ring-1 ring-red-500/30"
                        ]}>
                          <span class={[
                            "w-1.5 h-1.5 rounded-full",
                            @selected_agent.status == "active" && "bg-emerald-400 animate-pulse",
                            @selected_agent.status == "paused" && "bg-yellow-400",
                            @selected_agent.status == "pending" && "bg-amber-400 animate-pulse",
                            @selected_agent.status == "error" && "bg-red-400"
                          ]}>
                          </span>
                          {String.capitalize(@selected_agent.status)}
                        </span>
                      </div>
                      <p class="text-xs font-mono text-gray-500">
                        {@selected_agent.wallet_address}
                      </p>
                    </div>
                    <div class="flex items-center gap-2">
                      <%= if @selected_agent.status == "active" do %>
                        <button
                          phx-click="pause_agent"
                          class="px-3 py-1.5 rounded-lg ring-1 ring-yellow-500/30 bg-yellow-500/10 hover:bg-yellow-500/20 text-yellow-400 text-xs font-semibold transition-all"
                        >
                          ⏸ Pause
                        </button>
                      <% end %>
                      <%= if @selected_agent.status == "paused" do %>
                        <button
                          phx-click="resume_agent"
                          class="px-3 py-1.5 rounded-lg ring-1 ring-emerald-500/30 bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-400 text-xs font-semibold transition-all"
                        >
                          ▶ Resume
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Stats row --%>
                <div class="grid grid-cols-4 gap-3">
                  <%!-- Realized P&L --%>
                  <div class="rounded-xl bg-gray-900/60 ring-1 ring-white/[0.12] px-4 py-4">
                    <p class="text-xs text-gray-500 mb-1 uppercase tracking-wider font-medium">
                      Realized P&L
                    </p>
                    <%= if @pnl_stats && @pnl_stats.trade_count > 0 do %>
                      <p class={["text-3xl font-black tracking-tight", pnl_color(@pnl_stats.total_pnl)]}>
                        {if Decimal.gt?(@pnl_stats.total_pnl, 0), do: "+"}${@pnl_stats.total_pnl}
                      </p>
                      <p class="text-xs text-gray-600 mt-1">{@pnl_stats.trade_count} settled trades</p>
                    <% else %>
                      <p class="text-3xl font-black text-gray-700 tracking-tight">$0.00</p>
                      <p class="text-xs text-gray-700 mt-1">no trades yet</p>
                    <% end %>
                  </div>

                  <%!-- Win Rate --%>
                  <div class="rounded-xl bg-gray-900/60 ring-1 ring-white/[0.12] px-4 py-4">
                    <p class="text-xs text-gray-500 mb-1 uppercase tracking-wider font-medium">
                      Win Rate
                    </p>
                    <%= if @pnl_stats && @pnl_stats.trade_count > 0 do %>
                      <p class="text-3xl font-black text-white tracking-tight">
                        {win_rate(@pnl_stats.win_count, @pnl_stats.trade_count)}
                      </p>
                      <p class="text-xs text-gray-600 mt-1">
                        {@pnl_stats.win_count}W · {@pnl_stats.loss_count}L
                      </p>
                    <% else %>
                      <p class="text-3xl font-black text-gray-700 tracking-tight">—</p>
                      <p class="text-xs text-gray-700 mt-1">no data</p>
                    <% end %>
                  </div>

                  <%!-- Open Positions --%>
                  <div class="rounded-xl bg-gray-900/60 ring-1 ring-white/[0.12] px-4 py-4">
                    <p class="text-xs text-gray-500 mb-1 uppercase tracking-wider font-medium">
                      Open Positions
                    </p>
                    <p class="text-3xl font-black text-white tracking-tight">
                      {if @pnl_stats, do: @pnl_stats.open_count, else: 0}
                    </p>
                    <p class="text-xs text-gray-600 mt-1">
                      max {@selected_agent.max_open_positions}
                    </p>
                  </div>

                  <%!-- Wallet Balance --%>
                  <div class="rounded-xl bg-gray-900/60 ring-1 ring-white/[0.12] px-4 py-4">
                    <p class="text-xs text-gray-500 mb-1 uppercase tracking-wider font-medium">
                      Wallet Balance
                    </p>
                    <%= if @wallet_balance_eth do %>
                      <p class="text-3xl font-black text-violet-400 tracking-tight">
                        {@wallet_balance_eth}
                      </p>
                      <p class="text-xs text-gray-600 mt-1">KITE testnet</p>
                    <% else %>
                      <p class="text-3xl font-black text-gray-700 tracking-tight animate-pulse">
                        …
                      </p>
                      <p class="text-xs text-gray-700 mt-1">fetching on-chain</p>
                    <% end %>
                  </div>
                </div>

                <%!-- Spending limits strip --%>
                <div class="flex items-center gap-3 rounded-xl bg-gray-900/40 ring-1 ring-white/[0.12] px-5 py-3">
                  <span class="text-xs text-gray-600 font-medium uppercase tracking-wider mr-2">
                    Limits
                  </span>
                  <span class="text-xs text-gray-400">
                    <span class="text-gray-600">Daily</span> ${@selected_agent.daily_limit_usd}
                  </span>
                  <span class="text-gray-700">·</span>
                  <span class="text-xs text-gray-400">
                    <span class="text-gray-600">Per Trade</span>
                    ${@selected_agent.per_trade_limit_usd}
                  </span>
                  <span class="text-gray-700">·</span>
                  <span class="text-xs text-gray-400">
                    <span class="text-gray-600">Max Positions</span>
                    {@selected_agent.max_open_positions}
                  </span>
                  <span class="text-gray-700">·</span>
                  <span class="text-xs font-mono text-violet-500 truncate">
                    Vault: {if @selected_agent.vault_address,
                      do: String.slice(@selected_agent.vault_address, 0, 18) <> "…",
                      else: "not deployed"}
                  </span>
                </div>

                <%!-- Vault Activation Banner --%>
                <%= if @selected_agent.status == "pending" do %>
                  <div class="rounded-2xl ring-1 ring-amber-500/25 bg-gradient-to-br from-amber-500/5 to-amber-900/5 p-5">
                    <div class="flex items-start gap-4">
                      <div class="h-10 w-10 rounded-xl bg-amber-500/15 ring-1 ring-amber-500/25 flex items-center justify-center shrink-0">
                        <.icon name="hero-bolt" class="w-5 h-5 text-amber-400" />
                      </div>
                      <div class="flex-1 min-w-0">
                        <h3 class="text-sm font-bold text-amber-300 mb-1">
                          Vault not deployed — agent is standing by
                        </h3>
                        <p class="text-xs text-amber-400/60 mb-4">
                          Deploy the vault contract, then paste the address below to go live.
                          <br />
                          <code class="mt-1 inline-block bg-gray-900 px-2 py-1 rounded text-amber-300 font-mono">
                            python scripts/agent_onboard.py --private-key YOUR_KEY
                          </code>
                        </p>
                        <.form for={@vault_form} phx-submit="activate_vault" class="flex gap-2">
                          <input
                            type="text"
                            name="vault[vault_address]"
                            placeholder="0x vault contract address"
                            class="flex-1 rounded-lg bg-gray-900 ring-1 ring-white/10 focus:ring-amber-500/50 px-3 py-2 text-white font-mono text-sm placeholder-gray-600 outline-none transition-all"
                          />
                          <button
                            type="submit"
                            phx-disable-with="Activating…"
                            class="px-5 py-2 rounded-lg bg-amber-500 hover:bg-amber-400 text-gray-900 font-bold text-sm transition-colors whitespace-nowrap shadow-lg shadow-amber-500/20"
                          >
                            Activate →
                          </button>
                        </.form>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%!-- Live Trade Feed --%>
                <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/[0.12] overflow-hidden">
                  <div class="flex items-center justify-between px-5 py-4 border-b border-white/[0.10]">
                    <h3 class="text-sm font-bold text-white">Live Trade Feed</h3>
                    <div class="flex items-center gap-3">
                      <.link
                        navigate={~p"/trades"}
                        class="text-xs text-gray-500 hover:text-gray-300 transition-colors"
                      >
                        View all →
                      </.link>
                      <span class="flex items-center gap-1.5 text-xs font-medium text-emerald-400">
                        <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                        Live
                      </span>
                    </div>
                  </div>

                  <div id="trades" phx-update="stream">
                    <div class="hidden only:flex flex-col items-center justify-center py-16 gap-3">
                      <div class="w-10 h-10 rounded-xl bg-gray-800 flex items-center justify-center">
                        <.icon name="hero-arrow-trending-up" class="w-5 h-5 text-gray-600" />
                      </div>
                      <p class="text-sm text-gray-600">No trades yet</p>
                      <p class="text-xs text-gray-700">
                        <%= if @selected_agent.status == "active" do %>
                          Agent is live — first signal incoming
                        <% else %>
                          Activate the agent vault to start trading
                        <% end %>
                      </p>
                    </div>
                    <%= for {id, trade} <- @streams.trades do %>
                      <div
                        id={id}
                        class="flex items-center gap-4 px-5 py-3.5 border-b border-white/[0.10] last:border-0 hover:bg-white/[0.02] transition-colors"
                      >
                        <span class={[
                          "inline-flex items-center px-2.5 py-1 rounded-lg text-xs font-black uppercase tracking-wide min-w-16 justify-center",
                          trade.action == "buy" && "bg-emerald-500/15 text-emerald-400",
                          trade.action == "sell" && "bg-red-500/15 text-red-400"
                        ]}>
                          {String.upcase(trade.action || "")}
                        </span>
                        <div class="flex-1 min-w-0">
                          <p class="text-sm font-semibold text-white">{trade.market}</p>
                          <p class="text-xs text-gray-600 font-mono">
                            {trade.contracts}x contracts
                          </p>
                        </div>
                        <div class="text-right">
                          <p class="text-sm font-mono text-gray-300">
                            ${trade.fill_price}
                          </p>
                          <span class={[
                            "text-xs px-1.5 py-0.5 rounded font-medium",
                            trade.status == "open" && "text-blue-400",
                            trade.status == "settled" && "text-gray-500",
                            trade.status == "cancelled" && "text-yellow-500",
                            trade.status == "failed" && "text-red-500"
                          ]}>
                            {trade.status}
                          </span>
                        </div>
                        <%= if trade.realized_pnl do %>
                          <div class="text-right w-20 shrink-0">
                            <p class={[
                              "text-sm font-bold",
                              Decimal.gt?(trade.realized_pnl, 0) && "text-emerald-400",
                              Decimal.lt?(trade.realized_pnl, 0) && "text-red-400",
                              Decimal.eq?(trade.realized_pnl, 0) && "text-gray-500"
                            ]}>
                              {if Decimal.gt?(trade.realized_pnl, 0), do: "+"}${trade.realized_pnl}
                            </p>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
