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
      <div class="min-h-screen bg-gray-950 text-gray-100">
        <%!-- Back nav --%>
        <div class="border-b border-white/5 px-6 py-3">
          <div class="max-w-5xl mx-auto flex items-center gap-3">
            <.link
              navigate={~p"/dashboard"}
              class="flex items-center gap-1.5 text-xs text-gray-500 hover:text-gray-300 transition-colors"
            >
              <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
            </.link>
            <span class="text-gray-700">/</span>
            <span class="text-xs text-gray-400">New Agent</span>
          </div>
        </div>

        <div class="max-w-5xl mx-auto px-6 py-10 grid grid-cols-5 gap-8">
          <%!-- Left: form --%>
          <div class="col-span-3">
            <div class="mb-8">
              <div class="flex items-center gap-3 mb-4">
                <div class="w-10 h-10 rounded-xl bg-gradient-to-br from-violet-500 to-purple-600 flex items-center justify-center shadow-lg shadow-violet-500/25">
                  <.icon name="hero-cpu-chip" class="w-5 h-5 text-white" />
                </div>
                <div>
                  <h1 class="text-xl font-black text-white">Configure Your Agent</h1>
                  <p class="text-xs text-gray-500">Set identity and risk limits</p>
                </div>
              </div>
            </div>

            <div class="rounded-2xl bg-gray-900/60 ring-1 ring-white/5 p-6">
              <.form
                for={@form}
                id="agent-form"
                phx-change="validate"
                phx-submit="save"
                class="space-y-5"
              >
                <div>
                  <label class="block text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                    Agent Name
                  </label>
                  <.input
                    field={@form[:name]}
                    placeholder="e.g. Alpha Scalper, Kite Arb Bot"
                    class="w-full"
                  />
                </div>

                <div>
                  <label class="block text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                    Kite Wallet Address
                  </label>
                  <.input
                    field={@form[:wallet_address]}
                    placeholder="0x..."
                    class="w-full font-mono"
                  />
                  <p class="text-xs text-gray-600 mt-1">
                    Generate at
                    <a
                      href="https://faucet.gokite.ai"
                      target="_blank"
                      class="text-violet-500 hover:text-violet-400"
                    >
                      faucet.gokite.ai
                    </a>
                  </p>
                </div>

                <div class="grid grid-cols-2 gap-4">
                  <div>
                    <label class="block text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                      Daily Limit (USD)
                    </label>
                    <.input field={@form[:daily_limit_usd]} type="number" value="1000" />
                  </div>
                  <div>
                    <label class="block text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                      Per-Trade Limit (USD)
                    </label>
                    <.input field={@form[:per_trade_limit_usd]} type="number" value="500" />
                  </div>
                </div>

                <div>
                  <label class="block text-xs font-semibold text-gray-400 uppercase tracking-wider mb-2">
                    Max Open Positions
                  </label>
                  <.input field={@form[:max_open_positions]} type="number" value="10" />
                </div>

                <button
                  type="submit"
                  phx-disable-with="Deploying…"
                  class="w-full py-3 rounded-xl bg-gradient-to-r from-violet-600 to-purple-600 hover:from-violet-500 hover:to-purple-500 text-white font-bold text-sm transition-all shadow-xl shadow-violet-500/20 hover:shadow-violet-500/30"
                >
                  Create Agent →
                </button>
              </.form>
            </div>

            <p class="text-center text-xs text-gray-700 mt-5">
              🔒 Private keys never stored. Only your public wallet address is saved.
            </p>
          </div>

          <%!-- Right: what happens next --%>
          <div class="col-span-2 space-y-4 pt-2">
            <h3 class="text-xs font-bold text-gray-500 uppercase tracking-widest mb-5">
              What happens next
            </h3>

            <div class="flex gap-3">
              <div class="flex flex-col items-center">
                <div class="w-7 h-7 rounded-full bg-violet-500/20 ring-1 ring-violet-500/30 flex items-center justify-center shrink-0">
                  <span class="text-xs font-black text-violet-400">1</span>
                </div>
                <div class="w-px flex-1 bg-gray-800 mt-2"></div>
              </div>
              <div class="pb-6">
                <p class="text-sm font-semibold text-white">Create the agent</p>
                <p class="text-xs text-gray-500 mt-1 leading-relaxed">
                  Agent is registered with your spending limits. Status: <span class="text-amber-400">pending</span>.
                </p>
              </div>
            </div>

            <div class="flex gap-3">
              <div class="flex flex-col items-center">
                <div class="w-7 h-7 rounded-full bg-violet-500/20 ring-1 ring-violet-500/30 flex items-center justify-center shrink-0">
                  <span class="text-xs font-black text-violet-400">2</span>
                </div>
                <div class="w-px flex-1 bg-gray-800 mt-2"></div>
              </div>
              <div class="pb-6">
                <p class="text-sm font-semibold text-white">Deploy the vault</p>
                <p class="text-xs text-gray-500 mt-1 leading-relaxed">
                  Run the onboard script to deploy a TradingAgentVault on Kite testnet. Fund it at faucet.gokite.ai.
                </p>
                <code class="mt-2 block text-xs font-mono text-violet-400 bg-gray-900 rounded-lg px-3 py-2 ring-1 ring-white/5">
                  python scripts/agent_onboard.py
                </code>
              </div>
            </div>

            <div class="flex gap-3">
              <div class="flex flex-col items-center">
                <div class="w-7 h-7 rounded-full bg-emerald-500/20 ring-1 ring-emerald-500/30 flex items-center justify-center shrink-0">
                  <span class="text-xs font-black text-emerald-400">3</span>
                </div>
              </div>
              <div>
                <p class="text-sm font-semibold text-white">Go live</p>
                <p class="text-xs text-gray-500 mt-1 leading-relaxed">
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
