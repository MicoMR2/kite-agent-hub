defmodule KiteAgentHubWeb.AgentOnboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}
  alias KiteAgentHub.Trading.KiteAgent

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    form = to_form(KiteAgent.changeset(%KiteAgent{}, %{}))

    {:ok,
     assign(socket,
       organization: org,
       form: form,
       step: :configure
     )}
  end

  @impl true
  def handle_event("validate", %{"kite_agent" => params}, socket) do
    form =
      %KiteAgent{}
      |> KiteAgent.changeset(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", %{"kite_agent" => params}, socket) do
    org = socket.assigns.organization

    if org do
      attrs = Map.put(params, "organization_id", org.id)

      case Trading.create_agent(attrs) do
        {:ok, agent} ->
          {:noreply,
           socket
           |> put_flash(:info, "Agent #{agent.name} created. Deploy your vault to activate it.")
           |> push_navigate(to: ~p"/dashboard?agent_id=#{agent.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, form: to_form(changeset))}
      end
    else
      {:noreply, put_flash(socket, :error, "No workspace found. Create one first.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Back nav --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center gap-4">
            <.link
              navigate={~p"/dashboard"}
              class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
            >
              <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
            </.link>
            <span class="text-gray-700 hidden sm:block">|</span>
            <span class="text-sm font-black text-white uppercase tracking-widest hidden sm:block">
              New Agent
            </span>
          </div>
        </div>

        <div class="w-full px-4 sm:px-6 lg:px-8 py-10 grid grid-cols-1 lg:grid-cols-5 gap-10 lg:gap-16">
          <%!-- Left: form --%>
          <div class="lg:col-span-3">
            <div class="mb-10">
              <div class="flex flex-col sm:flex-row sm:items-center gap-4">
                <div class="w-12 h-12 rounded-xl border border-white/10 bg-white/[0.03] flex items-center justify-center shadow-[0_0_20px_rgba(255,255,255,0.05)] shrink-0">
                  <.icon name="hero-cpu-chip" class="w-6 h-6 text-white" />
                </div>
                <div>
                  <h1 class="text-3xl font-black text-white tracking-tight">Configure Your Agent</h1>
                  <p class="text-sm text-gray-500 mt-1 font-light tracking-wide">
                    Set identity and risk limits
                  </p>
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 sm:p-8">
              <.form
                for={@form}
                id="agent-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-6"
              >
                <div>
                  <label class="block text-xs font-bold text-gray-400 uppercase tracking-widest mb-3">
                    Agent Name
                  </label>
                  <.input
                    field={@form[:name]}
                    placeholder="e.g. Alpha Scalper, Kite Arb Bot"
                    class="w-full rounded-xl border border-white/10 bg-black/50 text-white placeholder-gray-600 focus:border-[#22c55e]/50 focus:ring-[#22c55e]/50 transition-all font-mono"
                  />
                </div>

                <div>
                  <label class="block text-xs font-bold text-gray-400 uppercase tracking-widest mb-3">
                    Kite Wallet Address
                  </label>
                  <.input
                    field={@form[:wallet_address]}
                    placeholder="0x..."
                    class="w-full rounded-xl border border-white/10 bg-black/50 text-white placeholder-gray-600 focus:border-[#22c55e]/50 focus:ring-[#22c55e]/50 transition-all font-mono"
                  />
                  <p class="text-xs text-gray-500 mt-2 font-mono">
                    Generate at
                    <a
                      href="https://faucet.gokite.ai"
                      target="_blank"
                      class="text-[#22c55e] hover:text-white transition-colors border-b border-[#22c55e]/30 hover:border-white"
                    >
                      faucet.gokite.ai
                    </a>
                  </p>
                </div>

                <div class="grid grid-cols-1 sm:grid-cols-2 gap-6">
                  <div>
                    <label class="block text-xs font-bold text-gray-400 uppercase tracking-widest mb-3">
                      Daily Limit (USD)
                    </label>
                    <.input
                      field={@form[:daily_limit_usd]}
                      type="number"
                      value="1000"
                      class="w-full rounded-xl border border-white/10 bg-black/50 text-white focus:border-[#22c55e]/50 focus:ring-[#22c55e]/50 transition-all font-mono"
                    />
                  </div>
                  <div>
                    <label class="block text-xs font-bold text-gray-400 uppercase tracking-widest mb-3">
                      Per-Trade Limit (USD)
                    </label>
                    <.input
                      field={@form[:per_trade_limit_usd]}
                      type="number"
                      value="500"
                      class="w-full rounded-xl border border-white/10 bg-black/50 text-white focus:border-[#22c55e]/50 focus:ring-[#22c55e]/50 transition-all font-mono"
                    />
                  </div>
                </div>

                <div>
                  <label class="block text-xs font-bold text-gray-400 uppercase tracking-widest mb-3">
                    Max Open Positions
                  </label>
                  <.input
                    field={@form[:max_open_positions]}
                    type="number"
                    value="10"
                    class="w-full sm:w-1/2 rounded-xl border border-white/10 bg-black/50 text-white focus:border-[#22c55e]/50 focus:ring-[#22c55e]/50 transition-all font-mono"
                  />
                </div>

                <div class="pt-4 mt-8 border-t border-white/5">
                  <button
                    type="submit"
                    phx-disable-with="Deploying…"
                    class="w-full py-4 rounded-xl border border-white/10 bg-white hover:bg-gray-200 text-black font-black uppercase tracking-widest text-sm transition-all shadow-[0_0_20px_rgba(255,255,255,0.1)] hover:shadow-[0_0_30px_rgba(255,255,255,0.2)]"
                  >
                    Create Agent →
                  </button>
                </div>
              </.form>
            </div>

            <p class="text-center text-[10px] text-gray-600 mt-6 uppercase tracking-widest font-bold">
              🔒 Private keys never stored. Only your public wallet address is saved.
            </p>
          </div>

          <%!-- Right: what happens next --%>
          <div class="lg:col-span-2 space-y-6 pt-2">
            <h3 class="text-xs font-bold text-gray-500 uppercase tracking-widest mb-8">
              What happens next
            </h3>

            <div class="flex gap-4">
              <div class="flex flex-col items-center">
                <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                  <span class="text-xs font-black text-white">1</span>
                </div>
                <div class="w-px flex-1 bg-white/10 mt-3"></div>
              </div>
              <div class="pb-8">
                <p class="text-base font-bold text-white tracking-tight">Create the agent</p>
                <p class="text-sm text-gray-500 mt-2 font-light leading-relaxed">
                  Agent is registered with your spending limits. Status will be <span class="text-gray-400 font-mono text-xs uppercase bg-white/5 px-1.5 py-0.5 rounded border border-white/10">pending</span>.
                </p>
              </div>
            </div>

            <div class="flex gap-4">
              <div class="flex flex-col items-center">
                <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                  <span class="text-xs font-black text-white">2</span>
                </div>
                <div class="w-px flex-1 bg-white/10 mt-3"></div>
              </div>
              <div class="pb-8">
                <p class="text-base font-bold text-white tracking-tight">Deploy the vault</p>
                <p class="text-sm text-gray-500 mt-2 font-light leading-relaxed">
                  Run the onboard script to deploy a TradingAgentVault on Kite testnet. Fund it at faucet.gokite.ai.
                </p>
                <code class="mt-4 block text-xs font-mono text-gray-300 bg-black/50 rounded-lg px-4 py-3 border border-white/10 shadow-inner">
                  python agent_onboard.py
                </code>
              </div>
            </div>

            <div class="flex gap-4">
              <div class="flex flex-col items-center">
                <div class="w-8 h-8 rounded-full border border-[#22c55e]/50 bg-[#22c55e]/10 flex items-center justify-center shrink-0 shadow-[0_0_10px_rgba(34,197,94,0.2)]">
                  <span class="text-xs font-black text-[#22c55e]">3</span>
                </div>
              </div>
              <div>
                <p class="text-base font-bold text-white tracking-tight">Go live</p>
                <p class="text-sm text-gray-500 mt-2 font-light leading-relaxed">
                  Paste the vault address on the dashboard. AgentRunner starts ticking. Claude generates signals. Trades execute on-chain.
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
