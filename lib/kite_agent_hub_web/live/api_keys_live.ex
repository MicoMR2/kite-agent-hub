defmodule KiteAgentHubWeb.ApiKeysLive do
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Credentials, Orgs, Trading}

  @providers [
    %{
      id: "alpaca",
      label: "Alpaca",
      hint: "Paper trading at paper-api.alpaca.markets",
      key_label: "API Key ID",
      secret_label: "API Secret Key"
    },
    %{
      id: "kalshi",
      label: "Kalshi",
      hint: "Demo trading at demo-api.kalshi.co",
      key_label: "API Key ID",
      secret_label: "RSA Private Key (PEM)"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    org = Orgs.get_org_for_user(user.id)

    agents = if org, do: Trading.list_agents(org.id), else: []
    agent = List.first(agents)
    configured = if org, do: Credentials.configured_providers(org.id), else: []
    credentials = if org, do: load_masked_credentials(org.id), else: %{}

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:agent, agent)
     |> assign(:providers, @providers)
     |> assign(:configured, configured)
     |> assign(:credentials, credentials)
     |> assign(:editing, nil)
     |> assign(:editing_agent, false)
     |> assign(:agent_errors, [])
     |> assign(:form_errors, %{})}
  end

  # ── Agent address editing ──────────────────────────────────────────────────────

  @impl true
  def handle_event("edit_agent", _params, socket) do
    {:noreply, assign(socket, editing_agent: true, agent_errors: [])}
  end

  def handle_event("cancel_agent", _params, socket) do
    {:noreply, assign(socket, editing_agent: false, agent_errors: [])}
  end

  def handle_event("save_agent", %{"vault_address" => vault_address}, socket) do
    agent = socket.assigns.agent

    case Trading.update_vault_address(agent, vault_address) do
      {:ok, updated_agent} ->
        {:noreply,
         socket
         |> assign(:agent, updated_agent)
         |> assign(:editing_agent, false)
         |> assign(:agent_errors, [])
         |> put_flash(:info, "Vault address updated.")}

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.flat_map(fn {_field, msgs} -> msgs end)

        {:noreply, assign(socket, :agent_errors, errors)}
    end
  end

  # ── API credential editing ─────────────────────────────────────────────────────

  def handle_event("edit", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, editing: provider)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form_errors: %{})}
  end

  def handle_event(
        "save",
        %{"provider" => provider, "key_id" => key_id, "secret" => secret},
        socket
      ) do
    org = socket.assigns.org

    case Credentials.upsert_credential(org.id, provider, %{"key_id" => key_id, "secret" => secret}) do
      {:ok, _} ->
        configured = Credentials.configured_providers(org.id)
        credentials = load_masked_credentials(org.id)

        {:noreply,
         socket
         |> assign(:configured, configured)
         |> assign(:credentials, credentials)
         |> assign(:editing, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "#{String.capitalize(provider)} credentials saved.")}

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:noreply, assign(socket, :form_errors, errors)}
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    org = socket.assigns.org
    Credentials.delete_credential(org.id, provider)

    configured = Credentials.configured_providers(org.id)
    credentials = load_masked_credentials(org.id)

    {:noreply,
     socket
     |> assign(:configured, configured)
     |> assign(:credentials, credentials)
     |> put_flash(:info, "#{String.capitalize(provider)} credentials removed.")}
  end

  defp load_masked_credentials(org_id) do
    ~w(alpaca kalshi)
    |> Enum.reduce(%{}, fn provider, acc ->
      case Credentials.get_credential(org_id, provider) do
        nil -> acc
        cred -> Map.put(acc, provider, %{key_id: Credentials.mask_key_id(cred.key_id)})
      end
    end)
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
              <.icon name="hero-arrow-left" class="w-3.5 h-3.5" /> Dashboard
            </.link>
            <span class="text-gray-700">|</span>
            <h1 class="text-sm font-black text-white uppercase tracking-widest">Settings</h1>
          </div>
        </div>

        <div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <%!-- Agent Addresses --%>
          <%= if @agent do %>
            <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="text-sm font-black text-white uppercase tracking-widest">
                    Agent Addresses
                  </h2>
                  <p class="text-xs text-gray-500 mt-0.5">{@agent.name}</p>
                </div>
              </div>

              <%= if @editing_agent do %>
                <form phx-submit="save_agent" class="space-y-4">
                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Wallet Address
                    </label>
                    <div class="w-full bg-black/20 border border-white/5 rounded-xl px-4 py-3 text-sm text-gray-600 font-mono truncate">
                      {@agent.wallet_address}
                    </div>
                    <p class="text-[10px] text-gray-600 mt-1">Wallet address cannot be changed — it is derived from your private key.</p>
                  </div>

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Vault Address
                    </label>
                    <input
                      type="text"
                      name="vault_address"
                      value={@agent.vault_address}
                      autocomplete="off"
                      placeholder="0x..."
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                    />
                    <p class="text-[10px] text-gray-500 mt-1">
                      Get this from <a href="https://testnet.kitescan.ai/" target="_blank" class="text-blue-400 hover:underline">Kitescan</a> after running agent_onboard.py, or use: 0x95fCee8cbdDaa3285DCE7b51EfE196fFE6A3f347 (demo vault)
                    </p>
                    <%= for err <- @agent_errors do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <div class="flex items-center gap-3 pt-1">
                    <button
                      type="submit"
                      class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="cancel_agent"
                      class="px-5 py-2 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20 transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </form>
              <% else %>
                <div class="space-y-3">
                  <div class="flex items-center justify-between">
                    <span class="text-[10px] font-bold text-gray-600 uppercase tracking-widest w-24 shrink-0">Wallet</span>
                    <span class="font-mono text-xs text-gray-400 truncate flex-1 text-right">
                      {@agent.wallet_address || "—"}
                    </span>
                  </div>
                  <div class="flex items-center justify-between">
                    <span class="text-[10px] font-bold text-gray-600 uppercase tracking-widest w-24 shrink-0">Vault</span>
                    <span class={["font-mono text-xs truncate flex-1 text-right", if(@agent.vault_address, do: "text-gray-400", else: "text-yellow-500 italic")]}>
                      {@agent.vault_address || "Not set — click Edit to add"}
                    </span>
                  </div>
                  <div class="pt-2">
                    <button
                      phx-click="edit_agent"
                      class="px-4 py-1.5 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20 transition-all"
                    >
                      Edit
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>

          <%!-- Security note --%>
          <p class="text-xs text-gray-600">
            API credentials are encrypted with AES-256-GCM before storage. Keys are never logged or exposed in the UI after saving.
          </p>

          <%!-- Provider API Keys --%>
          <%= for provider <- @providers do %>
            <% configured = provider.id in @configured %>
            <% existing = Map.get(@credentials, provider.id) %>
            <div class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="text-sm font-black text-white uppercase tracking-widest">
                    {provider.label}
                  </h2>
                  <p class="text-xs text-gray-500 mt-0.5">{provider.hint}</p>
                </div>
                <div class="flex items-center gap-2">
                  <%= if configured do %>
                    <span class="flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-widest text-emerald-400">
                      <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 shadow-[0_0_6px_#22c55e]">
                      </span>
                      Connected
                    </span>
                  <% else %>
                    <span class="text-[10px] font-bold uppercase tracking-widest text-gray-600">
                      Not configured
                    </span>
                  <% end %>
                </div>
              </div>

              <%= if @editing == provider.id do %>
                <form phx-submit="save" class="space-y-4">
                  <input type="hidden" name="provider" value={provider.id} />

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      {provider.key_label}
                    </label>
                    <input
                      type="text"
                      name="key_id"
                      autocomplete="off"
                      placeholder="Paste your key ID..."
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                    />
                    <%= if err = get_in(@form_errors, [:key_id, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      {provider.secret_label}
                    </label>
                    <textarea
                      name="secret"
                      autocomplete="off"
                      rows={if provider.id == "kalshi", do: 6, else: 2}
                      placeholder={
                        if provider.id == "kalshi",
                          do: "-----BEGIN RSA PRIVATE KEY-----\n...",
                          else: "Paste your secret key..."
                      }
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono resize-none"
                    ></textarea>
                    <%= if err = get_in(@form_errors, [:secret, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <div class="flex items-center gap-3 pt-1">
                    <button
                      type="submit"
                      class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors"
                    >
                      Save
                    </button>
                    <button
                      type="button"
                      phx-click="cancel"
                      class="px-5 py-2 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20 transition-colors"
                    >
                      Cancel
                    </button>
                  </div>
                </form>
              <% else %>
                <div class="flex items-center justify-between">
                  <div class="font-mono text-sm text-gray-400">
                    <%= if existing do %>
                      {existing.key_id}
                    <% else %>
                      <span class="text-gray-700 italic text-xs">No key stored</span>
                    <% end %>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="edit"
                      phx-value-provider={provider.id}
                      class="px-4 py-1.5 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20 transition-all"
                    >
                      {if configured, do: "Update", else: "Add"}
                    </button>
                    <%= if configured do %>
                      <button
                        phx-click="delete"
                        phx-value-provider={provider.id}
                        data-confirm={"Remove #{provider.label} credentials?"}
                        class="px-4 py-1.5 rounded-xl border border-red-500/20 text-xs font-bold uppercase tracking-widest text-red-500/60 hover:text-red-400 hover:border-red-500/40 transition-all"
                      >
                        Remove
                      </button>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
