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
      <div class="min-h-screen bg-gray-950 text-gray-100 flex items-center justify-center p-6">
        <div class="w-full max-w-lg">
          <div class="text-center mb-8">
            <div class="w-14 h-14 rounded-2xl bg-violet-500/15 flex items-center justify-center mx-auto mb-4">
              <.icon name="hero-cpu-chip" class="w-7 h-7 text-violet-400" />
            </div>
            <h1 class="text-2xl font-bold text-white">Onboard a Trading Agent</h1>
            <p class="text-sm text-gray-500 mt-2">
              Configure your agent's identity and spending limits. Deploy the vault after.
            </p>
          </div>

          <div class="rounded-2xl bg-gray-900 border border-gray-800 p-6">
            <.form for={@form} id="agent-form" phx-change="validate" phx-submit="save" class="space-y-5">
              <.input
                field={@form[:name]}
                label="Agent Name"
                placeholder="e.g. Kalshi Arb Bot"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white placeholder-gray-500 focus:border-violet-500 focus:outline-none"
              />
              <.input
                field={@form[:wallet_address]}
                label="Wallet Address"
                placeholder="0x..."
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white font-mono placeholder-gray-500 focus:border-violet-500 focus:outline-none"
              />
              <div class="grid grid-cols-2 gap-4">
                <.input
                  field={@form[:daily_limit_usd]}
                  type="number"
                  label="Daily Limit (USD)"
                  value="1000"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white focus:border-violet-500 focus:outline-none"
                />
                <.input
                  field={@form[:per_trade_limit_usd]}
                  type="number"
                  label="Per-Trade Limit (USD)"
                  value="500"
                  class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white focus:border-violet-500 focus:outline-none"
                />
              </div>
              <.input
                field={@form[:max_open_positions]}
                type="number"
                label="Max Open Positions"
                value="10"
                class="w-full rounded-lg bg-gray-800 border border-gray-700 px-3 py-2 text-white focus:border-violet-500 focus:outline-none"
              />

              <div class="rounded-lg bg-violet-500/10 border border-violet-500/20 p-3 text-xs text-violet-300">
                <p class="font-medium mb-1">After saving:</p>
                <ol class="list-decimal list-inside space-y-1 text-violet-400/80">
                  <li>Run <code class="bg-gray-800 px-1 rounded">python scripts/agent_onboard.py --private-key YOUR_KEY</code></li>
                  <li>Fund the vault with USDT at faucet.gokite.ai</li>
                  <li>Paste the vault address to activate your agent</li>
                </ol>
              </div>

              <button
                type="submit"
                phx-disable-with="Saving..."
                class="w-full py-2.5 rounded-lg bg-violet-600 hover:bg-violet-500 text-white font-medium text-sm transition-colors"
              >
                Create Agent
              </button>
            </.form>
          </div>

          <p class="text-center text-xs text-gray-600 mt-6">
            Private keys never leave your machine. The platform only stores your wallet address.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
