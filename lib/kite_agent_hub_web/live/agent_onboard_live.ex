defmodule KiteAgentHubWeb.AgentOnboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}
  alias KiteAgentHub.Trading.KiteAgent

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    form = to_form(KiteAgent.changeset(%KiteAgent{}, %{"agent_type" => "trading"}))

    {:ok,
     assign(socket,
       organization: org,
       form: form,
       agent_type: "trading",
       step: :configure
     )}
  end

  @impl true
  def handle_event("validate", %{"kite_agent" => params}, socket) do
    agent_type = Map.get(params, "agent_type", "trading")

    form =
      %KiteAgent{}
      |> KiteAgent.changeset(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form, agent_type: agent_type)}
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
        <%!-- Nav --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center gap-4">
            <.link
              navigate={~p"/dashboard"}
              class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
            >
              <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
              Dashboard
            </.link>
            <span class="text-gray-700">|</span>
            <h1 class="text-sm font-black text-white uppercase tracking-widest">New Agent</h1>
          </div>
        </div>

        <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-10 grid grid-cols-1 lg:grid-cols-5 gap-10 lg:gap-16">
          <%!-- Left: form --%>
          <div class="lg:col-span-3">
            <div class="mb-8">
              <div class="flex items-center gap-4">
                <div class="w-12 h-12 rounded-xl border border-white/10 bg-white/[0.03] flex items-center justify-center shadow-[0_0_20px_rgba(255,255,255,0.05)]">
                  <svg class="w-6 h-6 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25z" />
                  </svg>
                </div>
                <div>
                  <h1 class="text-2xl font-black text-white tracking-tight">Configure Your Agent</h1>
                  <p class="text-sm text-gray-500 mt-0.5">Set identity, wallet, and risk limits</p>
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
                <%!-- Agent Type Selector --%>
                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-3">
                    Agent Type
                  </label>
                  <div class="grid grid-cols-3 gap-2">
                    <%= for {type, label, desc} <- [{"trading", "Trading", "Executes live trades"}, {"research", "Research", "Signals only, no trades"}, {"conversational", "Conversational", "Analysis & coordination"}] do %>
                      <label class={[
                        "relative flex flex-col gap-1 cursor-pointer rounded-xl border p-3 transition-all",
                        if(@agent_type == type,
                          do: "border-white/30 bg-white/[0.06]",
                          else: "border-white/5 bg-white/[0.01] hover:border-white/15"
                        )
                      ]}>
                        <input
                          type="radio"
                          name={@form[:agent_type].name}
                          value={type}
                          checked={@agent_type == type}
                          class="sr-only"
                        />
                        <span class="text-xs font-bold text-white">{label}</span>
                        <span class="text-[10px] text-gray-500 leading-snug">{desc}</span>
                      </label>
                    <% end %>
                  </div>
                  <%= for {msg, _} <- @form[:agent_type].errors do %>
                    <p class="text-xs text-red-400 mt-1">{msg}</p>
                  <% end %>
                </div>

                <%!-- Agent Name --%>
                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Agent Name
                  </label>
                  <input
                    id={@form[:name].id}
                    name={@form[:name].name}
                    type="text"
                    value={Phoenix.HTML.Form.input_value(@form, :name)}
                    placeholder={
                      case @agent_type do
                        "research" -> "e.g. Market Scout, Alpha Researcher"
                        "conversational" -> "e.g. Strategy Advisor, Team Coordinator"
                        _ -> "e.g. Alpha Scalper, Kite Arb Bot"
                      end
                    }
                    spellcheck="false"
                    required
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                  />
                  <%= for {msg, _} <- @form[:name].errors do %>
                    <p class="text-xs text-red-400 mt-1">{msg}</p>
                  <% end %>
                </div>

                <%!-- Wallet Address — trading agents only --%>
                <%= if @agent_type == "trading" do %>
                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Kite Wallet Address
                    </label>
                    <input
                      id={@form[:wallet_address].id}
                      name={@form[:wallet_address].name}
                      type="text"
                      value={Phoenix.HTML.Form.input_value(@form, :wallet_address)}
                      placeholder="0x..."
                      spellcheck="false"
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                    />
                    <p class="text-xs text-gray-600 mt-2">
                      Get testnet tokens at
                      <a
                        href="https://faucet.gokite.ai"
                        target="_blank"
                        class="text-[#22c55e] hover:text-white transition-colors"
                      >
                        faucet.gokite.ai
                      </a>
                    </p>
                    <%= for {msg, _} <- @form[:wallet_address].errors do %>
                      <p class="text-xs text-red-400 mt-1">{msg}</p>
                    <% end %>
                  </div>
                <% else %>
                  <%!-- Hidden field so wallet_address isn't sent as nil but also not required --%>
                  <input type="hidden" name={@form[:wallet_address].name} value="" />
                <% end %>

                <div class="pt-4 mt-4 border-t border-white/5">
                  <button
                    type="submit"
                    phx-disable-with="Creating..."
                    class="w-full py-3.5 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors shadow-[0_0_20px_rgba(255,255,255,0.1)]"
                  >
                    Create Agent
                  </button>
                </div>
              </.form>
            </div>

            <%= if @agent_type == "trading" do %>
              <p class="text-center text-[10px] text-gray-600 mt-6 uppercase tracking-widest font-bold">
                Private keys never stored. Only your public wallet address is saved.
              </p>
            <% end %>
          </div>

          <%!-- Right: what happens next --%>
          <div class="lg:col-span-2 pt-2">
            <h3 class="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-8">
              What happens next
            </h3>

            <%= if @agent_type == "trading" do %>
              <div class="space-y-0">
                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                      <span class="text-[10px] font-black text-white">1</span>
                    </div>
                    <div class="w-px flex-1 bg-white/10 mt-2"></div>
                  </div>
                  <div class="pb-8">
                    <p class="text-sm font-bold text-white">Create the agent</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      Registered with your wallet. Status:
                      <span class="text-gray-400 font-mono text-[10px] uppercase bg-white/5 px-1.5 py-0.5 rounded border border-white/10">pending</span>
                    </p>
                  </div>
                </div>

                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                      <span class="text-[10px] font-black text-white">2</span>
                    </div>
                    <div class="w-px flex-1 bg-white/10 mt-2"></div>
                  </div>
                  <div class="pb-8">
                    <p class="text-sm font-bold text-white">Deploy the vault</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      Deploy a TradingAgentVault on Kite testnet. Fund it at faucet.gokite.ai.
                    </p>
                    <code class="mt-3 block text-[11px] font-mono text-gray-400 bg-black/50 rounded-lg px-4 py-2.5 border border-white/10">
                      python agent_onboard.py
                    </code>
                  </div>
                </div>

                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-[#22c55e]/40 bg-[#22c55e]/10 flex items-center justify-center shrink-0 shadow-[0_0_10px_rgba(34,197,94,0.15)]">
                      <span class="text-[10px] font-black text-[#22c55e]">3</span>
                    </div>
                  </div>
                  <div>
                    <p class="text-sm font-bold text-white">Go live</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      Paste the vault address on the dashboard. Trades execute on Alpaca + Kite chain.
                    </p>
                  </div>
                </div>
              </div>

              <div class="mt-10 rounded-xl border border-white/5 bg-white/[0.01] p-4">
                <p class="text-[10px] font-bold text-gray-600 uppercase tracking-widest mb-2">Kite Testnet</p>
                <div class="space-y-1.5 text-xs text-gray-500 font-mono">
                  <p>Chain ID: 2368</p>
                  <p>RPC: rpc-testnet.gokite.ai</p>
                  <p>Explorer: testnet.kitescan.ai</p>
                </div>
              </div>
            <% else %>
              <div class="space-y-0">
                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                      <span class="text-[10px] font-black text-white">1</span>
                    </div>
                    <div class="w-px flex-1 bg-white/10 mt-2"></div>
                  </div>
                  <div class="pb-8">
                    <p class="text-sm font-bold text-white">Create the agent</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      No wallet required. Agent is active immediately.
                    </p>
                  </div>
                </div>

                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-white/20 bg-white/[0.05] flex items-center justify-center shrink-0">
                      <span class="text-[10px] font-black text-white">2</span>
                    </div>
                    <div class="w-px flex-1 bg-white/10 mt-2"></div>
                  </div>
                  <div class="pb-8">
                    <p class="text-sm font-bold text-white">Copy the system prompt</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      From the dashboard, copy your agent's prompt and paste it into Claude or your LLM of choice.
                    </p>
                  </div>
                </div>

                <div class="flex gap-4">
                  <div class="flex flex-col items-center">
                    <div class="w-8 h-8 rounded-full border border-[#22c55e]/40 bg-[#22c55e]/10 flex items-center justify-center shrink-0 shadow-[0_0_10px_rgba(34,197,94,0.15)]">
                      <span class="text-[10px] font-black text-[#22c55e]">3</span>
                    </div>
                  </div>
                  <div>
                    <p class="text-sm font-bold text-white">Start analyzing</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      <%= if @agent_type == "research" do %>
                        Monitor markets, compute edge scores, and post signals to your trading agent.
                      <% else %>
                        Answer questions, summarize performance, and coordinate with the team.
                      <% end %>
                    </p>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

end
