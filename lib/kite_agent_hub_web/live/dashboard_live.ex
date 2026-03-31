defmodule KiteAgentHubWeb.DashboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}
  alias KiteAgentHub.Kite.{RPC, EdgeScorer}
  alias KiteAgentHub.TradingPlatforms.{AlpacaClient, KalshiClient}

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

    if connected?(socket) do
      if selected_agent do
        Phoenix.PubSub.subscribe(KiteAgentHub.PubSub, "agent:#{selected_agent.id}")
        fetch_chain_data(selected_agent)
      end

      send(self(), :load_edge_scores)
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
      |> assign(:active_tab, :overview)
      |> assign(:edge_scores, [])
      |> assign(:edge_scores_loading, connected?(socket))
      |> assign(:alpaca_data, nil)
      |> assign(:alpaca_history, [])
      |> assign(:kalshi_data, nil)
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
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = case tab do
      "overview"    -> :overview
      "wallet"      -> :wallet
      "edge_scorer" -> :edge_scorer
      "alpaca"      -> :alpaca
      "kalshi"      -> :kalshi
      _             -> :overview
    end

    socket =
      case tab_atom do
        :edge_scorer ->
          send(self(), :load_edge_scores)
          assign(socket, :edge_scores_loading, true)

        :alpaca ->
          send(self(), :load_alpaca)
          assign(socket, :alpaca_data, :loading)

        :kalshi ->
          send(self(), :load_kalshi)
          assign(socket, :kalshi_data, :loading)

        _ ->
          socket
      end

    {:noreply, assign(socket, :active_tab, tab_atom)}
  end

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

  # Async edge scorer loading
  def handle_info(:load_edge_scores, socket) do
    scores = EdgeScorer.score_all()
    {:noreply, socket |> assign(:edge_scores, scores) |> assign(:edge_scores_loading, false)}
  end

  # Async Alpaca data loading
  def handle_info(:load_alpaca, socket) do
    {:noreply, load_alpaca_data(socket)}
  end

  # Async Kalshi data loading
  def handle_info(:load_kalshi, socket) do
    {:noreply, load_kalshi_data(socket)}
  end

  # ── Private helpers ───────────────────────────────────────────────────────────

  defp load_alpaca_data(socket) do
    org = socket.assigns.organization

    with org when not is_nil(org) <- org,
         {:ok, credentials} <- credentials_module().fetch_secret(org.id, :alpaca),
         {key_id, secret} <- credentials,
         {:ok, account} <- AlpacaClient.account(key_id, secret),
         {:ok, positions} <- AlpacaClient.positions(key_id, secret),
         {:ok, history} <- AlpacaClient.portfolio_history(key_id, secret) do
      socket
      |> assign(:alpaca_data, %{account: account, positions: positions})
      |> assign(:alpaca_history, history)
    else
      nil -> assign(socket, :alpaca_data, :error)
      {:error, :not_configured} -> assign(socket, :alpaca_data, :not_configured)
      {:error, :unauthorized} -> assign(socket, :alpaca_data, :unauthorized)
      err ->
        require Logger
        Logger.error("DashboardLive: Alpaca load failed: #{inspect(err)}")
        assign(socket, :alpaca_data, :error)
    end
  end

  defp load_kalshi_data(socket) do
    org = socket.assigns.organization

    with org when not is_nil(org) <- org,
         {:ok, credentials} <- credentials_module().fetch_secret(org.id, :kalshi),
         {key_id, pem} <- credentials,
         {:ok, balance} <- KalshiClient.balance(key_id, pem),
         {:ok, positions} <- KalshiClient.positions(key_id, pem) do
      assign(socket, :kalshi_data, %{balance: balance, positions: positions})
    else
      nil -> assign(socket, :kalshi_data, :error)
      {:error, :not_configured} -> assign(socket, :kalshi_data, :not_configured)
      {:error, :unauthorized} -> assign(socket, :kalshi_data, :unauthorized)
      err ->
        require Logger
        Logger.error("DashboardLive: Kalshi load failed: #{inspect(err)}")
        assign(socket, :kalshi_data, :error)
    end
  end

  # Credentials module reference — allows PR #24 to be merged independently.
  # Raises a clear error if Credentials is not yet available.
  defp credentials_module do
    if Code.ensure_loaded?(KiteAgentHub.Credentials) do
      KiteAgentHub.Credentials
    else
      __MODULE__.CredentialsStub
    end
  end

  # Stub used before PR #24 (API key settings) is merged.
  defmodule CredentialsStub do
    def fetch_secret(_org_id, _provider), do: {:error, :not_configured}
  end

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
    Float.round(wei / 1_000_000_000_000_000_000, 4)
  end

  defp win_rate(_, 0), do: "0%"
  defp win_rate(wins, total), do: "#{Float.round(wins / total * 100, 1)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Top nav bar --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center justify-between">
            <div class="flex items-center gap-3">
              <div class="h-8 w-8 rounded-lg border border-white/10 bg-white/[0.03] flex items-center justify-center shadow-[0_0_15px_rgba(255,255,255,0.05)]">
                <.icon name="hero-bolt" class="w-4 h-4 text-white" />
              </div>
              <div>
                <span class="text-sm font-black text-white tracking-tight uppercase">
                  Kite Agent Hub
                </span>
                <span class="text-gray-600 mx-2">|</span>
                <span class="text-xs text-gray-400 font-mono tracking-widest uppercase">
                  {if @organization, do: @organization.name, else: "No workspace"}
                </span>
              </div>
            </div>
            <div class="flex items-center gap-4">
              <%= if @block_number do %>
                <div class="hidden sm:flex items-center gap-2 px-3 py-1.5 rounded-full border border-white/10 bg-white/[0.02] shadow-[0_0_10px_rgba(255,255,255,0.02)]">
                  <span class="w-1.5 h-1.5 rounded-full bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse">
                  </span>
                  <span class="text-xs font-mono text-gray-300 tracking-wider">
                    BLOCK {@block_number}
                  </span>
                </div>
              <% end %>
              <.link
                navigate={~p"/trades"}
                class="text-xs text-gray-400 hover:text-white transition-colors font-semibold uppercase tracking-widest"
              >
                Trades
              </.link>
              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-1.5 px-4 py-1.5 rounded-xl border border-white/10 bg-white/[0.05] hover:bg-white/[0.1] text-white text-xs font-bold transition-all uppercase tracking-widest"
              >
                <.icon name="hero-plus" class="w-3.5 h-3.5" /> New Agent
              </.link>
              <.link
                navigate={~p"/api-keys"}
                class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
              >
                <.icon name="hero-key" class="w-3.5 h-3.5" /> API Keys
              </.link>
              <.link
                navigate={~p"/users/settings"}
                class="text-xs text-gray-400 hover:text-white transition-colors font-mono hidden sm:block"
              >
                {@current_scope.user.email}
              </.link>
              <.link
                href={~p"/users/log-out"}
                method="delete"
                class="text-xs text-gray-500 hover:text-gray-300 transition-colors uppercase font-semibold tracking-widest"
              >
                Sign out
              </.link>
            </div>
          </div>
        </div>

        <%!-- Tab navigation --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/60 backdrop-blur-sm px-4 sm:px-6 lg:px-8">
          <nav class="flex gap-1" id="dashboard-tabs">
            <%= for {label, tab_key} <- [{"Overview", "overview"}, {"Kite Wallet", "wallet"}, {"EdgeScorer", "edge_scorer"}, {"Alpaca", "alpaca"}, {"Kalshi", "kalshi"}] do %>
              <button
                id={"tab-#{tab_key}"}
                phx-click="switch_tab"
                phx-value-tab={tab_key}
                class={[
                  "px-4 py-3 text-xs font-bold uppercase tracking-widest transition-all border-b-2",
                  if(@active_tab == String.to_atom(tab_key),
                    do: "border-[#22c55e] text-white",
                    else: "border-transparent text-gray-500 hover:text-gray-300"
                  )
                ]}
              >
                {label}
              </button>
            <% end %>
          </nav>
        </div>

        <%= if @agents == [] do %>
          <%!-- ═══════════════ EMPTY STATE — first-time user ═══════════════ --%>
          <div class="w-full px-4 sm:px-6 lg:px-8 py-20 text-center relative overflow-hidden">
            <div class="absolute inset-0 flex items-center justify-center pointer-events-none">
              <div class="w-[600px] h-[600px] rounded-full bg-white/[0.02] blur-3xl absolute top-10 left-1/2 -translate-x-1/2">
              </div>
            </div>
            <div class="relative z-10 max-w-4xl mx-auto">
              <div class="w-20 h-20 rounded-2xl border border-white/10 bg-white/[0.03] flex items-center justify-center mx-auto mb-8 shadow-[0_0_30px_rgba(255,255,255,0.05)]">
                <.icon name="hero-cpu-chip" class="w-10 h-10 text-white" />
              </div>
              <h1 class="text-5xl font-black text-white mb-6 tracking-tight">
                Autonomous AI Trading.<br />
                <span class="text-gray-400">
                  On-Chain. Unstoppable.
                </span>
              </h1>
              <p class="text-lg text-gray-500 max-w-xl mx-auto mb-12 font-light">
                Deploy a trading agent powered by Claude AI. It reads market data, generates signals, and executes trades on Kite chain — around the clock, fully autonomous.
              </p>

              <div class="grid grid-cols-1 sm:grid-cols-3 gap-6 mb-12">
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 text-left hover:bg-white/[0.04] transition-all">
                  <div class="w-10 h-10 rounded-xl border border-white/10 bg-black flex items-center justify-center mb-4">
                    <span class="text-lg font-black text-white">1</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Create an Agent</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Name your agent, set spending limits, and provide your Kite wallet address. Takes 30 seconds.
                  </p>
                </div>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 text-left hover:bg-white/[0.04] transition-all">
                  <div class="w-10 h-10 rounded-xl border border-white/10 bg-black flex items-center justify-center mb-4">
                    <span class="text-lg font-black text-white">2</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Deploy a Vault</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Deploy the TradingAgentVault contract on Kite testnet. Your keys never leave your machine.
                  </p>
                </div>
                <div class="rounded-2xl border border-[#22c55e]/30 bg-[#22c55e]/[0.05] backdrop-blur-md p-6 text-left shadow-[0_0_15px_rgba(34,197,94,0.1)]">
                  <div class="w-10 h-10 rounded-xl border border-[#22c55e]/50 bg-black flex items-center justify-center mb-4 text-[#22c55e] shadow-[0_0_10px_rgba(34,197,94,0.2)]">
                    <span class="text-lg font-black">3</span>
                  </div>
                  <h3 class="text-sm font-bold text-white mb-2">Watch It Trade</h3>
                  <p class="text-xs text-gray-400 leading-relaxed font-light">
                    Activate the agent. Claude generates signals, and trades execute instantly on-chain.
                  </p>
                </div>
              </div>

              <.link
                navigate={~p"/agents/new"}
                class="inline-flex items-center gap-2 px-10 py-4 rounded-xl border border-white/10 bg-white/[0.08] hover:bg-white/[0.12] text-white text-base font-bold transition-all shadow-[0_0_20px_rgba(255,255,255,0.05)] hover:-translate-y-0.5 transform tracking-wide"
              >
                <.icon name="hero-bolt" class="w-5 h-5" /> Launch Your First Agent
              </.link>
              <p class="text-xs text-gray-600 mt-6 font-mono">
                Chain ID 2368 · Powered by Claude
              </p>
            </div>
          </div>
        <% else %>
          <%!-- ═══════════════ MAIN DASHBOARD ═══════════════ --%>
          <%= if @active_tab == :overview do %>
          <div class="w-full px-4 sm:px-6 lg:px-8 py-6 flex flex-col lg:flex-row gap-6">
            <%!-- ── Sidebar: Agent List ── --%>
            <div class="w-full lg:w-72 shrink-0 space-y-4">
              <div class="flex items-center justify-between px-2">
                <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">Agents</h2>
                <span class="text-xs text-gray-600 font-mono tracking-wider">
                  {length(@agents)} total
                </span>
              </div>

              <div class="space-y-2">
                <%= for agent <- @agents do %>
                  <.link
                    patch={~p"/dashboard?agent_id=#{agent.id}"}
                    class={[
                      "block rounded-xl p-4 transition-all border group",
                      @selected_agent && @selected_agent.id == agent.id &&
                        "border-white/20 bg-white/[0.05] shadow-[0_0_15px_rgba(255,255,255,0.02)]",
                      (!@selected_agent || @selected_agent.id != agent.id) &&
                        "border-white/5 bg-white/[0.01] hover:border-white/10 hover:bg-white/[0.03]"
                    ]}
                  >
                    <div class="flex items-start justify-between gap-2 mb-2">
                      <span class={[
                        "text-sm font-bold truncate tracking-wide transition-colors",
                        @selected_agent && @selected_agent.id == agent.id && "text-white",
                        (!@selected_agent || @selected_agent.id != agent.id) &&
                          "text-gray-400 group-hover:text-gray-200"
                      ]}>
                        {agent.name}
                      </span>
                      <span class={[
                        "w-2 h-2 rounded-full shrink-0 mt-1",
                        agent.status == "active" && "bg-[#22c55e] shadow-[0_0_8px_#22c55e]",
                        agent.status == "paused" && "bg-yellow-400",
                        agent.status == "pending" && "bg-gray-500",
                        agent.status == "error" && "bg-[#ef4444]"
                      ]}>
                      </span>
                    </div>
                    <p class="text-xs text-gray-600 font-mono truncate mb-3">
                      {String.slice(agent.wallet_address || "", 0, 12)}…
                    </p>
                    <div class="flex items-center">
                      <span class={[
                        "text-[10px] px-2 py-0.5 rounded border uppercase tracking-widest font-bold",
                        agent.status == "active" &&
                          "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e]",
                        agent.status == "paused" &&
                          "bg-yellow-500/10 border-yellow-500/20 text-yellow-400",
                        agent.status == "pending" && "bg-gray-500/10 border-gray-500/20 text-gray-400",
                        agent.status == "error" &&
                          "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                      ]}>
                        {agent.status}
                      </span>
                    </div>
                  </.link>
                <% end %>
              </div>

              <.link
                navigate={~p"/agents/new"}
                class="flex items-center justify-center gap-2 w-full rounded-xl py-4 border border-dashed border-white/10 bg-white/[0.01] hover:bg-white/[0.03] hover:border-white/20 text-gray-500 hover:text-white transition-all text-xs font-bold uppercase tracking-widest"
              >
                <.icon name="hero-plus" class="w-4 h-4" /> Add Agent
              </.link>
            </div>

            <%!-- ── Main Panel ── --%>
            <div class="flex-1 space-y-6 min-w-0">
              <%= if @selected_agent do %>
                <%!-- Agent header --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                  <div class="flex flex-col sm:flex-row sm:items-start justify-between gap-4">
                    <div>
                      <div class="flex items-center gap-4 mb-2">
                        <h2 class="text-2xl font-black text-white tracking-tight">
                          {@selected_agent.name}
                        </h2>
                        <span class={[
                          "inline-flex items-center gap-2 px-3 py-1 rounded-full border text-[10px] uppercase tracking-widest font-bold",
                          @selected_agent.status == "active" &&
                            "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e]",
                          @selected_agent.status == "paused" &&
                            "bg-yellow-500/10 border-yellow-500/20 text-yellow-400",
                          @selected_agent.status == "pending" &&
                            "bg-gray-500/10 border-gray-500/20 text-gray-400",
                          @selected_agent.status == "error" &&
                            "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                        ]}>
                          <span class={[
                            "w-1.5 h-1.5 rounded-full",
                            @selected_agent.status == "active" &&
                              "bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse",
                            @selected_agent.status == "paused" && "bg-yellow-400",
                            @selected_agent.status == "pending" && "bg-gray-400 animate-pulse",
                            @selected_agent.status == "error" && "bg-[#ef4444]"
                          ]}>
                          </span>
                          {@selected_agent.status}
                        </span>
                      </div>
                      <p class="text-xs font-mono text-gray-500 select-all">
                        {@selected_agent.wallet_address}
                      </p>
                    </div>
                    <div class="flex items-center gap-3 shrink-0">
                      <%= if @selected_agent.status == "active" do %>
                        <button
                          phx-click="pause_agent"
                          class="px-4 py-2 rounded-xl border border-yellow-500/30 bg-yellow-500/10 hover:bg-yellow-500/20 text-yellow-500 text-xs font-bold uppercase tracking-widest transition-all"
                        >
                          Pause
                        </button>
                      <% end %>
                      <%= if @selected_agent.status == "paused" do %>
                        <button
                          phx-click="resume_agent"
                          class="px-4 py-2 rounded-xl border border-[#22c55e]/30 bg-[#22c55e]/10 hover:bg-[#22c55e]/20 text-[#22c55e] text-xs font-bold uppercase tracking-widest transition-all"
                        >
                          Resume
                        </button>
                      <% end %>
                    </div>
                  </div>
                </div>

                <%!-- Stats row --%>
                <div class="grid grid-cols-2 lg:grid-cols-4 gap-4">
                  <%!-- Realized P&L --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 relative overflow-hidden group">
                    <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                      Realized P&L
                    </p>
                    <%= if @pnl_stats && @pnl_stats.trade_count > 0 do %>
                      <p class={[
                        "text-4xl sm:text-5xl font-black tracking-tighter truncate transition-all duration-300",
                        Decimal.gt?(@pnl_stats.total_pnl, 0) &&
                          "text-[#22c55e] drop-shadow-[0_0_15px_rgba(34,197,94,0.3)]",
                        Decimal.lt?(@pnl_stats.total_pnl, 0) &&
                          "text-[#ef4444] drop-shadow-[0_0_15px_rgba(239,68,68,0.3)]",
                        Decimal.eq?(@pnl_stats.total_pnl, 0) && "text-gray-300"
                      ]}>
                        {if Decimal.gt?(@pnl_stats.total_pnl, 0), do: "+"}${@pnl_stats.total_pnl}
                      </p>
                      <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                        {@pnl_stats.trade_count} Settled Trades
                      </p>
                    <% else %>
                      <p class="text-4xl sm:text-5xl font-black text-gray-700 tracking-tighter">
                        $0.00
                      </p>
                      <p class="text-[10px] text-gray-600 mt-2 font-mono uppercase tracking-widest">
                        No Trades
                      </p>
                    <% end %>
                  </div>

                  <%!-- Win Rate --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                    <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                      Win Rate
                    </p>
                    <%= if @pnl_stats && @pnl_stats.trade_count > 0 do %>
                      <p class="text-4xl sm:text-5xl font-black text-white tracking-tighter">
                        {win_rate(@pnl_stats.win_count, @pnl_stats.trade_count)}
                      </p>
                      <p class="text-[10px] text-gray-400 mt-2 font-mono tracking-widest">
                        <span class="text-[#22c55e]">{@pnl_stats.win_count}W</span>
                        <span class="mx-1 text-gray-700">/</span>
                        <span class="text-[#ef4444]">{@pnl_stats.loss_count}L</span>
                      </p>
                    <% else %>
                      <p class="text-4xl sm:text-5xl font-black text-gray-700 tracking-tighter">—</p>
                      <p class="text-[10px] text-gray-600 mt-2 font-mono tracking-widest uppercase">
                        No Data
                      </p>
                    <% end %>
                  </div>

                  <%!-- Open Positions --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                    <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                      Open Positions
                    </p>
                    <p class="text-4xl sm:text-5xl font-black text-white tracking-tighter">
                      {if @pnl_stats, do: @pnl_stats.open_count, else: 0}
                    </p>
                    <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                      Max {@selected_agent.max_open_positions} allowed
                    </p>
                  </div>

                  <%!-- Wallet Balance --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
                    <p class="text-[10px] text-gray-500 mb-2 uppercase tracking-widest font-bold">
                      Wallet Balance
                    </p>
                    <%= if @wallet_balance_eth do %>
                      <p class="text-3xl sm:text-4xl lg:text-3xl xl:text-4xl font-black text-white tracking-tighter truncate">
                        {@wallet_balance_eth}
                      </p>
                      <p class="text-[10px] text-gray-500 mt-2 font-mono uppercase tracking-widest">
                        ETH (Testnet)
                      </p>
                    <% else %>
                      <p class="text-4xl sm:text-5xl font-black text-gray-700 tracking-tighter animate-pulse">
                        …
                      </p>
                      <p class="text-[10px] text-gray-600 mt-2 font-mono uppercase tracking-widest">
                        Fetching
                      </p>
                    <% end %>
                  </div>
                </div>

                <%!-- Spending limits strip --%>
                <div class="flex flex-wrap items-center gap-x-6 gap-y-3 rounded-2xl border border-white/5 bg-white/[0.01] px-6 py-4">
                  <span class="text-[10px] text-gray-600 font-bold uppercase tracking-widest">
                    Limits Config
                  </span>
                  <div class="flex items-baseline gap-2">
                    <span class="text-[10px] text-gray-500 uppercase tracking-widest">Daily</span>
                    <span class="text-sm font-mono text-gray-300">
                      ${@selected_agent.daily_limit_usd}
                    </span>
                  </div>
                  <div class="hidden sm:block text-gray-800">|</div>
                  <div class="flex items-baseline gap-2">
                    <span class="text-[10px] text-gray-500 uppercase tracking-widest">Per Trade</span>
                    <span class="text-sm font-mono text-gray-300">
                      ${@selected_agent.per_trade_limit_usd}
                    </span>
                  </div>
                  <div class="hidden sm:block text-gray-800">|</div>
                  <div class="flex items-baseline gap-2">
                    <span class="text-[10px] text-gray-500 uppercase tracking-widest">Positions</span>
                    <span class="text-sm font-mono text-gray-300">
                      {@selected_agent.max_open_positions}
                    </span>
                  </div>
                  <div class="hidden sm:block text-gray-800">|</div>
                  <div class="flex items-baseline gap-2 min-w-0">
                    <span class="text-[10px] text-gray-500 uppercase tracking-widest">Vault</span>
                    <span class="text-sm font-mono text-gray-400 truncate select-all">
                      {if @selected_agent.vault_address,
                        do: String.slice(@selected_agent.vault_address, 0, 18) <> "…",
                        else: "Not deployed"}
                    </span>
                  </div>
                </div>

                <%!-- Vault Activation Banner --%>
                <%= if @selected_agent.status == "pending" do %>
                  <div class="rounded-2xl border border-gray-600/30 bg-gray-600/5 p-6 backdrop-blur-md">
                    <div class="flex flex-col md:flex-row items-start md:items-center gap-6">
                      <div class="h-12 w-12 rounded-xl border border-gray-500/30 bg-gray-500/10 flex items-center justify-center shrink-0">
                        <.icon name="hero-command-line" class="w-6 h-6 text-gray-300" />
                      </div>
                      <div class="flex-1 min-w-0 space-y-3">
                        <div>
                          <h3 class="text-base font-bold text-white tracking-tight">
                            Vault not deployed
                          </h3>
                          <p class="text-[11px] text-gray-400 tracking-wide mt-1">
                            Deploy the vault contract, then paste the address below to go live.
                          </p>
                        </div>
                        <.form
                          for={@vault_form}
                          phx-submit="activate_vault"
                          class="flex flex-col sm:flex-row gap-3"
                        >
                          <input
                            type="text"
                            name="vault[vault_address]"
                            placeholder="0x vault contract address"
                            class="flex-1 rounded-xl border border-white/10 bg-black/50 px-4 py-3 text-white font-mono text-sm placeholder-gray-600 focus:outline-none focus:border-white/30 focus:ring-1 focus:ring-white/30 transition-all shadow-inner"
                          />
                          <button
                            type="submit"
                            phx-disable-with="Activating…"
                            class="px-8 py-3 rounded-xl border border-white/10 bg-white text-black font-black uppercase tracking-widest text-xs hover:bg-gray-200 transition-colors whitespace-nowrap shadow-[0_0_20px_rgba(255,255,255,0.2)]"
                          >
                            Activate Vault
                          </button>
                        </.form>
                      </div>
                    </div>
                  </div>
                <% end %>

                <%!-- Live Trade Feed --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md overflow-hidden">
                  <div class="flex items-center justify-between px-6 py-5 border-b border-white/10">
                    <h3 class="text-sm font-black text-white uppercase tracking-widest">
                      Live Trade Feed
                    </h3>
                    <div class="flex items-center gap-4">
                      <.link
                        navigate={~p"/trades"}
                        class="text-[10px] text-gray-500 hover:text-white uppercase tracking-widest font-bold transition-colors"
                      >
                        View all ↗
                      </.link>
                      <div class="flex items-center gap-2 px-2.5 py-1 rounded bg-[#22c55e]/10 border border-[#22c55e]/20">
                        <span class="w-1.5 h-1.5 rounded-full bg-[#22c55e] shadow-[0_0_8px_#22c55e] animate-pulse">
                        </span>
                        <span class="text-[10px] font-bold text-[#22c55e] uppercase tracking-widest">
                          Live
                        </span>
                      </div>
                    </div>
                  </div>

                  <div id="trades" phx-update="stream" class="divide-y divide-white/5">
                    <div class="hidden only:flex flex-col items-center justify-center py-20 px-4 text-center">
                      <div class="w-12 h-12 rounded-xl border border-white/5 bg-white/[0.02] flex items-center justify-center mb-4">
                        <.icon name="hero-chart-bar" class="w-6 h-6 text-gray-600" />
                      </div>
                      <p class="text-sm font-bold text-gray-400">No trades yet</p>
                      <p class="text-xs text-gray-600 mt-2 font-mono">
                        <%= if @selected_agent.status == "active" do %>
                          Agent is scanning for signals
                        <% else %>
                          Deploy vault to initialize trading
                        <% end %>
                      </p>
                    </div>

                    <%= for {id, trade} <- @streams.trades do %>
                      <div
                        id={id}
                        class="flex flex-col sm:flex-row sm:items-center gap-4 px-6 py-4 hover:bg-white/[0.02] transition-colors group"
                      >
                        <%!-- Action indicator --%>
                        <div class="shrink-0 flex sm:block items-center justify-between w-full sm:w-16">
                          <span class={[
                            "w-full inline-flex items-center justify-center px-2 py-1.5 rounded-lg border text-[10px] font-black uppercase tracking-widest",
                            trade.action == "buy" &&
                              "bg-[#22c55e]/10 border-[#22c55e]/20 text-[#22c55e] group-hover:bg-[#22c55e]/20",
                            trade.action == "sell" &&
                              "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444] group-hover:bg-[#ef4444]/20"
                          ]}>
                            {trade.action || "UNKN"}
                          </span>
                        </div>

                        <%!-- Market info --%>
                        <div class="flex-1 min-w-0">
                          <div class="flex items-center gap-2">
                            <p class="text-base font-black text-white tracking-tight">
                              {trade.market}
                            </p>
                            <span class={[
                              "text-[9px] px-1.5 py-0.5 rounded border uppercase tracking-widest font-bold",
                              trade.status == "open" &&
                                "bg-blue-500/10 border-blue-500/20 text-blue-400",
                              trade.status == "settled" &&
                                "bg-gray-500/10 border-gray-500/20 text-gray-400",
                              trade.status == "cancelled" &&
                                "bg-yellow-500/10 border-yellow-500/20 text-yellow-500",
                              trade.status == "failed" &&
                                "bg-[#ef4444]/10 border-[#ef4444]/20 text-[#ef4444]"
                            ]}>
                              {trade.status}
                            </span>
                          </div>
                          <p class="text-[11px] text-gray-500 font-mono mt-0.5">
                            {trade.contracts}x contracts
                          </p>
                        </div>

                        <%!-- Fill & PNL --%>
                        <div class="flex sm:flex-col items-end justify-between sm:justify-center gap-2 sm:gap-1">
                          <p class="text-sm font-mono font-bold text-gray-300">
                            ${trade.fill_price}
                          </p>
                          <%= if trade.realized_pnl do %>
                            <p class={[
                              "text-sm font-bold font-mono",
                              Decimal.gt?(trade.realized_pnl, 0) && "text-[#22c55e]",
                              Decimal.lt?(trade.realized_pnl, 0) && "text-[#ef4444]",
                              Decimal.eq?(trade.realized_pnl, 0) && "text-gray-500"
                            ]}>
                              {if Decimal.gt?(trade.realized_pnl, 0), do: "+"}${@trade.realized_pnl ||
                                trade.realized_pnl}
                            </p>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
          <% end %>

          <%!-- ═══════════════ KITE WALLET TAB ═══════════════ --%>
          <%= if @active_tab == :wallet do %>
          <div class="w-full px-4 sm:px-6 lg:px-8 py-8 max-w-3xl">
            <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest mb-6">Kite Wallet</h2>
            <%= if @selected_agent do %>
              <div class="space-y-4">
                <%!-- Wallet address --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                  <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">Wallet Address</p>
                  <p class="font-mono text-sm text-white break-all">{@selected_agent.wallet_address || "—"}</p>
                  <%= if @selected_agent.wallet_address do %>
                    <a
                      href={"https://testnet.kitescan.ai/address/#{@selected_agent.wallet_address}"}
                      target="_blank"
                      class="text-xs text-[#22c55e] hover:underline mt-2 inline-block font-mono"
                    >
                      View on Kitescan ↗
                    </a>
                  <% end %>
                </div>
                <%!-- Vault address --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                  <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">Vault Address</p>
                  <p class="font-mono text-sm text-white break-all">
                    {if @selected_agent.vault_address, do: @selected_agent.vault_address, else: "Not set — paste vault address above"}
                  </p>
                  <%= if @selected_agent.vault_address do %>
                    <a
                      href={"https://testnet.kitescan.ai/address/#{@selected_agent.vault_address}"}
                      target="_blank"
                      class="text-xs text-[#22c55e] hover:underline mt-2 inline-block font-mono"
                    >
                      View vault on Kitescan ↗
                    </a>
                  <% end %>
                </div>
                <%!-- Balance --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                  <p class="text-xs text-gray-500 uppercase tracking-widest mb-2 font-bold">KITE Balance</p>
                  <p class="text-3xl font-black text-white">
                    {if @wallet_balance_eth, do: "#{@wallet_balance_eth} KITE", else: "—"}
                  </p>
                </div>
                <%!-- Chain info --%>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6 flex items-center justify-between">
                  <div>
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-1 font-bold">Network</p>
                    <p class="text-sm text-white font-mono">Kite Testnet · Chain 2368</p>
                  </div>
                  <div class="text-right">
                    <p class="text-xs text-gray-500 uppercase tracking-widest mb-1 font-bold">Block</p>
                    <p class="text-sm text-white font-mono">{@block_number || "—"}</p>
                  </div>
                </div>
              </div>
            <% else %>
              <p class="text-gray-500 text-sm">No agent selected.</p>
            <% end %>
          </div>
          <% end %>

          <%!-- ═══════════════ EDGESCORER TAB ═══════════════ --%>
          <%= if @active_tab == :edge_scorer do %>
          <div class="w-full px-4 sm:px-6 lg:px-8 py-8">
            <div class="flex items-center justify-between mb-6">
              <h2 class="text-xs font-bold text-gray-500 uppercase tracking-widest">EdgeScorer — Market Signal Scores</h2>
              <button
                phx-click="switch_tab"
                phx-value-tab="edge_scorer"
                class="text-xs text-gray-500 hover:text-white transition-colors font-mono uppercase tracking-widest"
              >
                ↻ Refresh
              </button>
            </div>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <%= for score <- @edge_scores do %>
                <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 hover:border-white/20 transition-all">
                  <%!-- Market header --%>
                  <div class="flex items-center justify-between mb-4">
                    <span class="text-sm font-black text-white tracking-tight">{score.market}</span>
                    <span class={[
                      "text-xs font-bold uppercase tracking-widest px-3 py-1 rounded-full border",
                      score.recommendation == :go   && "text-[#22c55e] border-[#22c55e]/30 bg-[#22c55e]/10",
                      score.recommendation == :hold  && "text-[#f59e0b] border-[#f59e0b]/30 bg-[#f59e0b]/10",
                      score.recommendation == :no    && "text-[#ef4444] border-[#ef4444]/30 bg-[#ef4444]/10"
                    ]}>
                      {String.upcase(Atom.to_string(score.recommendation))}
                    </span>
                  </div>
                  <%!-- Score bar --%>
                  <div class="mb-4">
                    <div class="flex items-center justify-between mb-1">
                      <span class="text-xs text-gray-500 font-mono uppercase tracking-widest">Edge Score</span>
                      <span class="text-2xl font-black text-white">{score.score}</span>
                    </div>
                    <div class="h-1.5 rounded-full bg-white/10 overflow-hidden">
                      <div
                        class={[
                          "h-full rounded-full transition-all",
                          score.score >= 75 && "bg-[#22c55e]",
                          score.score >= 50 && score.score < 75 && "bg-[#f59e0b]",
                          score.score < 50  && "bg-[#ef4444]"
                        ]}
                        style={"width: #{score.score}%"}
                      >
                      </div>
                    </div>
                  </div>
                  <%!-- Market data --%>
                  <div class="space-y-2 text-xs font-mono">
                    <div class="flex justify-between text-gray-400">
                      <span>Price</span>
                      <span class="text-white">${score.price}</span>
                    </div>
                    <div class="flex justify-between text-gray-400">
                      <span>24h Change</span>
                      <span class={[
                        score.change_24h >= 0 && "text-[#22c55e]",
                        score.change_24h < 0  && "text-[#ef4444]"
                      ]}>
                        {if score.change_24h >= 0, do: "+", else: ""}{score.change_24h}%
                      </span>
                    </div>
                    <div class="flex justify-between text-gray-400">
                      <span>Trend</span>
                      <span class="text-white">{String.replace(score.trend, "_", " ")}</span>
                    </div>
                    <div class="flex justify-between text-gray-400">
                      <span>RSI (approx)</span>
                      <span class="text-white">{score.rsi}</span>
                    </div>
                  </div>
                  <%!-- Breakdown --%>
                  <div class="mt-4 pt-4 border-t border-white/10 grid grid-cols-2 gap-2 text-xs font-mono text-gray-500">
                    <span>Trend: <span class="text-gray-300">{score.breakdown.trend}/40</span></span>
                    <span>RSI: <span class="text-gray-300">{score.breakdown.rsi}/30</span></span>
                    <span>Volume: <span class="text-gray-300">{score.breakdown.volume}/20</span></span>
                    <span>Δ24h: <span class="text-gray-300">{score.breakdown.change}/10</span></span>
                  </div>
                </div>
              <% end %>
              <%= if @edge_scores == [] do %>
                <div class="md:col-span-3 text-center py-12 text-gray-500 text-sm">
                  Fetching market data...
                </div>
              <% end %>
            </div>
          </div>
          <% end %>

          <%!-- Alpaca Tab --%>
          <%= if @active_tab == :alpaca do %>
            <div class="px-4 sm:px-6 lg:px-8 py-6 space-y-6">
              <%= case @alpaca_data do %>
                <% :loading -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm animate-pulse">Loading Alpaca account...</p>
                  </div>
                <% :not_configured -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm mb-3">Alpaca API keys not configured.</p>
                    <.link navigate={~p"/api-keys"} class="text-xs font-bold text-white underline">Add keys in Settings →</.link>
                  </div>
                <% :unauthorized -> %>
                  <div class="rounded-2xl border border-red-500/20 bg-red-500/5 p-6 text-center">
                    <p class="text-red-400 text-sm">Alpaca credentials invalid — check your API key in Settings.</p>
                  </div>
                <% :error -> %>
                  <div class="rounded-2xl border border-yellow-500/20 bg-yellow-500/5 p-6 text-center">
                    <p class="text-yellow-400 text-sm">Could not reach Alpaca API. Try refreshing.</p>
                  </div>
                <% nil -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm">Click the Alpaca tab to load your paper account.</p>
                  </div>
                <% data -> %>
                  <%!-- Account Summary --%>
                  <div class="grid grid-cols-2 sm:grid-cols-4 gap-4">
                    <%= for {label, val, color} <- [
                      {"Portfolio Value", "$#{:erlang.float_to_binary(data.account.portfolio_value || 0.0, decimals: 2)}", "text-white"},
                      {"Equity", "$#{:erlang.float_to_binary(data.account.equity || 0.0, decimals: 2)}", "text-emerald-400"},
                      {"Cash", "$#{:erlang.float_to_binary(data.account.cash || 0.0, decimals: 2)}", "text-gray-300"},
                      {"Buying Power", "$#{:erlang.float_to_binary(data.account.buying_power || 0.0, decimals: 2)}", "text-blue-400"}
                    ] do %>
                      <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-4">
                        <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">{label}</p>
                        <p class={"text-lg font-black tabular-nums #{color}"}>{val}</p>
                      </div>
                    <% end %>
                  </div>

                  <%!-- Equity Sparkline --%>
                  <%= if length(@alpaca_history) > 1 do %>
                    <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                      <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-4">Equity Curve (30D)</p>
                      <svg viewBox="0 0 400 80" class="w-full h-20" preserveAspectRatio="none">
                        <polyline
                          points={sparkline_points(@alpaca_history, 400, 80)}
                          fill="none"
                          stroke="#22c55e"
                          stroke-width="1.5"
                          vector-effect="non-scaling-stroke"
                        />
                      </svg>
                    </div>
                  <% end %>

                  <%!-- Positions --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10">
                      <h3 class="text-xs font-black text-white uppercase tracking-widest">Open Positions</h3>
                    </div>
                    <%= if data.positions == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No open positions.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ~w(Symbol Side Qty Avg\ Entry Current P&L) do %>
                              <th class="px-4 py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">{h}</th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for p <- data.positions do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-4 py-3 font-black text-white">{p.symbol}</td>
                              <td class="px-4 py-3 text-gray-400">{p.side}</td>
                              <td class="px-4 py-3 tabular-nums text-gray-300">{p.qty}</td>
                              <td class="px-4 py-3 tabular-nums font-mono text-gray-400">${:erlang.float_to_binary(p.avg_entry || 0.0, decimals: 2)}</td>
                              <td class="px-4 py-3 tabular-nums font-mono text-gray-300">${:erlang.float_to_binary(p.current_price || 0.0, decimals: 2)}</td>
                              <td class={"px-4 py-3 tabular-nums font-mono font-bold #{if (p.unrealized_pl || 0) >= 0, do: "text-emerald-400", else: "text-red-400"}"}>
                                {if (p.unrealized_pl || 0) >= 0, do: "+", else: ""}${:erlang.float_to_binary(abs(p.unrealized_pl || 0.0), decimals: 2)}
                              </td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Kalshi Tab --%>
          <%= if @active_tab == :kalshi do %>
            <div class="px-4 sm:px-6 lg:px-8 py-6 space-y-6">
              <%= case @kalshi_data do %>
                <% :loading -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm animate-pulse">Loading Kalshi account...</p>
                  </div>
                <% :not_configured -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm mb-3">Kalshi API keys not configured.</p>
                    <.link navigate={~p"/api-keys"} class="text-xs font-bold text-white underline">Add keys in Settings →</.link>
                  </div>
                <% :unauthorized -> %>
                  <div class="rounded-2xl border border-red-500/20 bg-red-500/5 p-6 text-center">
                    <p class="text-red-400 text-sm">Kalshi credentials invalid — check your API key and PEM in Settings.</p>
                  </div>
                <% :error -> %>
                  <div class="rounded-2xl border border-yellow-500/20 bg-yellow-500/5 p-6 text-center">
                    <p class="text-yellow-400 text-sm">Could not reach Kalshi API. Try refreshing.</p>
                  </div>
                <% nil -> %>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-10 text-center">
                    <p class="text-gray-500 text-sm">Click the Kalshi tab to load your demo portfolio.</p>
                  </div>
                <% data -> %>
                  <%!-- Balance --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-6">
                    <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">Available Balance</p>
                    <p class="text-3xl font-black text-white tabular-nums">
                      ${:erlang.float_to_binary(data.balance.available_balance, decimals: 2)}
                    </p>
                  </div>

                  <%!-- Positions --%>
                  <div class="rounded-2xl border border-white/10 bg-white/[0.02] overflow-x-auto">
                    <div class="px-6 py-4 border-b border-white/10">
                      <h3 class="text-xs font-black text-white uppercase tracking-widest">Open Positions</h3>
                    </div>
                    <%= if data.positions == [] do %>
                      <p class="px-6 py-8 text-center text-sm text-gray-600">No open positions.</p>
                    <% else %>
                      <table class="w-full text-sm">
                        <thead>
                          <tr class="border-b border-white/5">
                            <%= for h <- ~w(Market Side Contracts Avg\ Price Current Value) do %>
                              <th class="px-4 py-3 text-left text-[10px] font-bold text-gray-500 uppercase tracking-widest whitespace-nowrap">{h}</th>
                            <% end %>
                          </tr>
                        </thead>
                        <tbody class="divide-y divide-white/5">
                          <%= for p <- data.positions do %>
                            <tr class="hover:bg-white/[0.02]">
                              <td class="px-4 py-3 text-white text-xs font-mono">{p.title}</td>
                              <td class="px-4 py-3 text-gray-400">{p.side}</td>
                              <td class="px-4 py-3 tabular-nums text-gray-300">{p.contracts}</td>
                              <td class="px-4 py-3 tabular-nums font-mono text-gray-400">${:erlang.float_to_binary(p.avg_price, decimals: 2)}</td>
                              <td class="px-4 py-3 tabular-nums font-mono text-gray-300">${:erlang.float_to_binary(p.current_price, decimals: 2)}</td>
                              <td class="px-4 py-3 tabular-nums font-mono text-white">${:erlang.float_to_binary(p.value, decimals: 2)}</td>
                            </tr>
                          <% end %>
                        </tbody>
                      </table>
                    <% end %>
                  </div>
              <% end %>
            </div>
          <% end %>

        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ── SVG sparkline helper ───────────────────────────────────────────────────────

  defp sparkline_points(history, width, height) when length(history) > 1 do
    values = Enum.map(history, & &1.v)
    min_v = Enum.min(values)
    max_v = Enum.max(values)
    range = max(max_v - min_v, 0.01)
    count = length(history) - 1

    history
    |> Enum.with_index()
    |> Enum.map(fn {%{v: v}, i} ->
      x = i / count * width
      y = height - (v - min_v) / range * height
      "#{Float.round(x, 1)},#{Float.round(y, 1)}"
    end)
    |> Enum.join(" ")
  end

  defp sparkline_points(_, _, _), do: ""
end
