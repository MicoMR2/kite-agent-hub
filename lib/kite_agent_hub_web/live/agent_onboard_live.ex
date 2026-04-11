defmodule KiteAgentHubWeb.AgentOnboardLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Trading}
  alias KiteAgentHub.Trading.KiteAgent

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    orgs = Orgs.list_orgs_for_user(user.id)
    org = List.first(orgs)

    form = build_form(%{"agent_type" => "trading"}, org)

    {:ok,
     assign(socket,
       organization: org,
       form: form,
       agent_type: "trading",
       step: :configure
     )}
  end

  @impl true
  def handle_event("select_type", %{"type" => type}, socket)
      when type in ~w(trading research conversational) do
    # Preserve whatever the user has typed; just swap the agent_type.
    prior_params = current_form_params(socket)
    params = Map.put(prior_params, "agent_type", type)
    form = build_form(params, socket.assigns.organization)

    {:noreply, assign(socket, agent_type: type, form: form)}
  end

  def handle_event("validate", %{"kite_agent" => params}, socket) do
    agent_type = Map.get(params, "agent_type", socket.assigns.agent_type)
    form = build_form(params, socket.assigns.organization)

    {:noreply, assign(socket, form: form, agent_type: agent_type)}
  end

  def handle_event("review", %{"kite_agent" => params}, socket) do
    agent_type = Map.get(params, "agent_type", socket.assigns.agent_type)
    org = socket.assigns.organization

    changeset = changeset_with_org(params, org)
    form = to_form(Map.put(changeset, :action, :validate))

    cond do
      is_nil(org) ->
        {:noreply,
         socket
         |> put_flash(:error, "No workspace found. Create one first.")
         |> assign(form: form, agent_type: agent_type, step: :configure)}

      changeset.valid? ->
        {:noreply, assign(socket, form: form, agent_type: agent_type, step: :confirm)}

      true ->
        {:noreply,
         socket
         |> put_flash(:error, review_error_message(changeset))
         |> assign(form: form, agent_type: agent_type, step: :configure)}
    end
  end

  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, step: :configure)}
  end

  def handle_event("save", _params, socket) do
    org = socket.assigns.organization

    if org do
      params =
        socket.assigns.form.params
        |> Map.put("organization_id", org.id)
        |> Map.put("agent_type", socket.assigns.agent_type)
        |> Map.put("status", initial_status(socket.assigns.agent_type))

      case Trading.create_agent(params) do
        {:ok, agent} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{agent.name} created.")
           |> push_navigate(to: ~p"/dashboard?agent_id=#{agent.id}")}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, review_error_message(changeset))
           |> assign(form: to_form(changeset), step: :configure)}
      end
    else
      {:noreply, put_flash(socket, :error, "No workspace found. Create one first.")}
    end
  end

  # --- helpers ---

  defp build_form(params, org) do
    params
    |> changeset_with_org(org)
    |> Map.put(:action, :validate)
    |> to_form()
  end

  defp changeset_with_org(params, nil), do: KiteAgent.changeset(%KiteAgent{}, params)

  defp changeset_with_org(params, org) do
    KiteAgent.changeset(%KiteAgent{}, Map.put(params, "organization_id", org.id))
  end

  defp current_form_params(socket) do
    form = socket.assigns.form

    %{
      "name" => Phoenix.HTML.Form.input_value(form, :name) || "",
      "wallet_address" => Phoenix.HTML.Form.input_value(form, :wallet_address) || ""
    }
  end

  defp initial_status("trading"), do: "pending"
  defp initial_status(_), do: "active"

  defp review_error_message(changeset) do
    case changeset.errors do
      [{field, {msg, _}} | _] -> "#{humanize_field(field)} #{msg}"
      _ -> "Please fix the errors below."
    end
  end

  defp humanize_field(:wallet_address), do: "Wallet address"
  defp humanize_field(:organization_id), do: "Workspace"
  defp humanize_field(field), do: field |> Atom.to_string() |> String.capitalize()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <%!-- Nav --%>
        <div class="border-b border-white/10 bg-[#0a0a0f]/80 backdrop-blur-md sticky top-0 z-10 px-4 sm:px-6 lg:px-8 py-3">
          <div class="w-full flex items-center gap-4">
            <%= if @step == :confirm do %>
              <button
                phx-click="back"
                class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
              >
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
                Edit
              </button>
            <% else %>
              <.link
                navigate={~p"/dashboard"}
                class="flex items-center gap-2 px-3 py-1.5 rounded-lg border border-white/5 bg-white/[0.02] hover:bg-white/[0.05] hover:border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white transition-all"
              >
                <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7"/></svg>
                Dashboard
              </.link>
            <% end %>
            <span class="text-gray-700">|</span>
            <h1 class="text-sm font-black text-white uppercase tracking-widest">
              <%= if @step == :confirm, do: "Confirm Agent", else: "New Agent" %>
            </h1>
            <%!-- Step indicator --%>
            <div class="ml-auto flex items-center gap-2">
              <span class={[
                "w-2 h-2 rounded-full",
                if(@step == :configure, do: "bg-white", else: "bg-white/30")
              ]}></span>
              <span class={[
                "w-2 h-2 rounded-full",
                if(@step == :confirm, do: "bg-[#22c55e]", else: "bg-white/10")
              ]}></span>
            </div>
          </div>
        </div>

        <div class="max-w-5xl mx-auto px-4 sm:px-6 lg:px-8 py-10 grid grid-cols-1 lg:grid-cols-5 gap-10 lg:gap-16">
          <%!-- Left: form or confirm --%>
          <div class="lg:col-span-3">
            <%= if @step == :configure do %>
              <%!-- STEP 1: Configure --%>
              <div class="mb-8">
                <div class="flex items-center gap-4">
                  <div class="w-12 h-12 rounded-xl border border-white/10 bg-white/[0.03] flex items-center justify-center shadow-[0_0_20px_rgba(255,255,255,0.05)]">
                    <svg class="w-6 h-6 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25z" />
                    </svg>
                  </div>
                  <div>
                    <h1 class="text-2xl font-black text-white tracking-tight">Configure Your Agent</h1>
                    <p class="text-sm text-gray-500 mt-0.5">Choose type, name, and connect a wallet if needed</p>
                  </div>
                </div>
              </div>

              <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 sm:p-8">
                <.form
                  for={@form}
                  id="agent-form"
                  phx-change="validate"
                  phx-submit="review"
                  class="space-y-6"
                >
                  <%!-- Agent Type Selector --%>
                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-3">
                      Agent Type <span class="text-red-400">*</span>
                    </label>
                    <div class="grid grid-cols-3 gap-2">
                      <%= for {type, label, desc, icon} <- [
                        {"trading", "Trading", "Executes live trades on Alpaca & Kalshi", "hero-currency-dollar"},
                        {"research", "Research", "Analyzes markets and posts signals only", "hero-magnifying-glass"},
                        {"conversational", "Conversational", "Answers questions and coordinates agents", "hero-chat-bubble-left-right"}
                      ] do %>
                        <button
                          type="button"
                          phx-click="select_type"
                          phx-value-type={type}
                          class={[
                            "relative flex flex-col items-start gap-1.5 cursor-pointer rounded-xl border p-3 transition-all text-left w-full",
                            if(@agent_type == type,
                              do: "border-white/40 bg-white/[0.08] shadow-[0_0_15px_rgba(255,255,255,0.05)]",
                              else: "border-white/5 bg-white/[0.01] hover:border-white/20 hover:bg-white/[0.04]"
                            )
                          ]}
                        >
                          <%= if @agent_type == type do %>
                            <span class="absolute top-2 right-2 w-2 h-2 rounded-full bg-[#22c55e] shadow-[0_0_6px_#22c55e]"></span>
                          <% end %>
                          <.icon name={icon} class={["w-4 h-4 mb-0.5", if(@agent_type == type, do: "text-white", else: "text-gray-500")]} />
                          <span class={["text-xs font-bold", if(@agent_type == type, do: "text-white", else: "text-gray-400")]}>{label}</span>
                          <span class="text-[10px] text-gray-600 leading-snug">{desc}</span>
                        </button>
                      <% end %>
                    </div>
                    <%!-- Hidden field to carry agent_type in form submission --%>
                    <input type="hidden" name={@form[:agent_type].name} value={@agent_type} />
                  </div>

                  <%!-- Agent Name --%>
                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Agent Name <span class="text-red-400">*</span>
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
                        Kite Wallet Address <span class="text-red-400">*</span>
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
                    <input type="hidden" name={@form[:wallet_address].name} value="" />
                  <% end %>

                  <div class="pt-4 mt-4 border-t border-white/5">
                    <button
                      type="submit"
                      phx-disable-with="Reviewing..."
                      class="w-full py-3.5 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors shadow-[0_0_20px_rgba(255,255,255,0.1)]"
                    >
                      Review Agent →
                    </button>
                  </div>
                </.form>
              </div>

              <%= if @agent_type == "trading" do %>
                <p class="text-center text-[10px] text-gray-600 mt-6 uppercase tracking-widest font-bold">
                  Private keys never stored. Only your public wallet address is saved.
                </p>
              <% end %>

            <% else %>
              <%!-- STEP 2: Confirm --%>
              <div class="mb-8">
                <div class="flex items-center gap-4">
                  <div class="w-12 h-12 rounded-xl border border-[#22c55e]/30 bg-[#22c55e]/[0.06] flex items-center justify-center shadow-[0_0_20px_rgba(34,197,94,0.1)]">
                    <svg class="w-6 h-6 text-[#22c55e]" fill="none" viewBox="0 0 24 24" stroke="currentColor" stroke-width="1.5">
                      <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                    </svg>
                  </div>
                  <div>
                    <h1 class="text-2xl font-black text-white tracking-tight">Confirm Agent</h1>
                    <p class="text-sm text-gray-500 mt-0.5">Review before creating</p>
                  </div>
                </div>
              </div>

              <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6 sm:p-8 space-y-5">
                <%!-- Summary rows --%>
                <div class="flex items-center justify-between py-3 border-b border-white/5">
                  <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">Type</span>
                  <span class={[
                    "text-xs font-bold px-3 py-1 rounded-full border uppercase tracking-widest",
                    case @agent_type do
                      "trading" -> "text-white border-white/20 bg-white/[0.05]"
                      "research" -> "text-blue-400 border-blue-500/20 bg-blue-500/[0.05]"
                      _ -> "text-purple-400 border-purple-500/20 bg-purple-500/[0.05]"
                    end
                  ]}>
                    {String.capitalize(@agent_type)}
                  </span>
                </div>

                <div class="flex items-center justify-between py-3 border-b border-white/5">
                  <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">Name</span>
                  <span class="text-sm font-mono text-white">
                    {Phoenix.HTML.Form.input_value(@form, :name)}
                  </span>
                </div>

                <%= if @agent_type == "trading" do %>
                  <div class="flex items-center justify-between py-3 border-b border-white/5">
                    <span class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">Wallet</span>
                    <span class="text-xs font-mono text-gray-300">
                      {String.slice(Phoenix.HTML.Form.input_value(@form, :wallet_address) || "", 0, 20)}…
                    </span>
                  </div>
                  <div class="rounded-xl border border-yellow-500/20 bg-yellow-500/[0.04] p-4">
                    <p class="text-xs text-yellow-300 leading-relaxed">
                      After creation, go to the dashboard and paste your TradingAgentVault address to activate trading.
                    </p>
                  </div>
                <% else %>
                  <div class="rounded-xl border border-blue-500/20 bg-blue-500/[0.04] p-4">
                    <p class="text-xs text-blue-300 leading-relaxed">
                      No wallet required. After creation, copy your agent's system prompt from the dashboard and paste it into Claude Code or your LLM.
                    </p>
                  </div>
                <% end %>

                <div class="pt-2 flex gap-3">
                  <button
                    type="button"
                    phx-click="back"
                    class="flex-1 py-3 rounded-xl border border-white/10 text-gray-400 text-xs font-bold uppercase tracking-widest hover:border-white/20 hover:text-white transition-all"
                  >
                    ← Edit
                  </button>
                  <button
                    type="button"
                    phx-click="save"
                    phx-disable-with="Creating..."
                    class="flex-[2] py-3 rounded-xl bg-[#22c55e] text-black text-xs font-black uppercase tracking-widest hover:bg-[#16a34a] transition-colors shadow-[0_0_20px_rgba(34,197,94,0.2)]"
                  >
                    Confirm & Create Agent
                  </button>
                </div>
              </div>
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
                      Your agent is registered with status:
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
                    <p class="text-sm font-bold text-white">Paste your vault address</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      On the dashboard, enter your deployed TradingAgentVault address. This activates on-chain spend limits and settlement.
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
                    <p class="text-sm font-bold text-white">Connect your LLM & trade</p>
                    <p class="text-xs text-gray-500 mt-1.5 leading-relaxed">
                      Copy your agent's system prompt and paste it into Claude Code or Claude Desktop. Trades execute on Alpaca, Kalshi, and settle on Kite chain.
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
                      On the dashboard, click the <span class="text-emerald-400 font-semibold">Agent Context</span> button to reveal the system prompt. Paste it into Claude or your LLM.
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
