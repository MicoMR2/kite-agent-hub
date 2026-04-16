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

    configured = if org, do: Credentials.configured_providers(org.id), else: []
    credentials = if org, do: load_masked_credentials(org.id), else: %{}

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:providers, @providers)
     |> assign(:configured, configured)
     |> assign(:credentials, credentials)
     |> assign(:editing, nil)
     |> assign(:form_errors, %{})}
  end

  # Agent-level editing (wallet, vault, tokens) moved to AgentsLive
  # (/users/settings/agents) in PR-B of the agent-mgmt split. This
  # LiveView is now org-level credentials only.

  # ── API credential editing ─────────────────────────────────────────────────────

  @impl true
  def handle_event("edit", %{"provider" => provider}, socket) do
    {:noreply, assign(socket, editing: provider)}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply, assign(socket, editing: nil, form_errors: %{})}
  end

  def handle_event(
        "save",
        %{"provider" => provider, "key_id" => key_id, "secret" => secret} = params,
        socket
      ) do
    org = socket.assigns.org

    env =
      case Map.get(params, "env") do
        "live" -> "live"
        _ -> "paper"
      end

    case Credentials.upsert_credential(org.id, provider, %{
           "key_id" => key_id,
           "secret" => secret,
           "env" => env
         }) do
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
        nil ->
          acc

        cred ->
          Map.put(acc, provider, %{
            key_id: Credentials.mask_key_id(cred.key_id),
            env: cred.env || "paper"
          })
      end
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-gray-100">
        <KiteAgentHubWeb.SettingsNav.render active={:api_keys} />

        <div class="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <%!-- Agent wallet/vault editing moved to Settings > Agents. --%>

          <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-5 text-xs text-gray-500">
            Looking for agent wallets, vaults, or API tokens?
            <.link
              navigate={~p"/users/settings/agents"}
              class="text-white font-bold underline underline-offset-2"
            >
              Manage agents →
            </.link>
          </div>

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

                  <%!-- Environment toggle: paper/demo is the safe default --%>
                  <% current_env = (existing && existing.env) || "paper" %>
                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Environment
                    </label>
                    <div class="flex gap-2">
                      <label class={[
                        "flex-1 cursor-pointer rounded-xl border px-4 py-3 text-center transition-all",
                        current_env == "paper" && "border-emerald-500/40 bg-emerald-500/10",
                        current_env != "paper" && "border-white/10 bg-white/[0.02] hover:border-white/20"
                      ]}>
                        <input type="radio" name="env" value="paper" checked={current_env == "paper"} class="sr-only" />
                        <span class="text-xs font-black uppercase tracking-widest text-white">
                          {if provider.id == "kalshi", do: "Demo", else: "Paper"}
                        </span>
                        <p class="text-[10px] text-gray-500 mt-1">Safe sandbox — no real money</p>
                      </label>
                      <label class={[
                        "flex-1 cursor-pointer rounded-xl border px-4 py-3 text-center transition-all",
                        current_env == "live" && "border-red-500/40 bg-red-500/10",
                        current_env != "live" && "border-white/10 bg-white/[0.02] hover:border-white/20"
                      ]}>
                        <input type="radio" name="env" value="live" checked={current_env == "live"} class="sr-only" />
                        <span class="text-xs font-black uppercase tracking-widest text-white">Live</span>
                        <p class="text-[10px] text-gray-500 mt-1">Real funds — trades are final</p>
                      </label>
                    </div>
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
                  <div class="font-mono text-sm text-gray-400 flex items-center gap-2">
                    <%= if existing do %>
                      {existing.key_id}
                      <span class={[
                        "text-[10px] font-black uppercase tracking-widest px-2 py-0.5 rounded border",
                        existing.env == "live" && "text-red-400 border-red-500/30 bg-red-500/10",
                        existing.env != "live" && "text-emerald-400 border-emerald-500/30 bg-emerald-500/10"
                      ]}>
                        {if existing.env == "live", do: "Live", else: (if provider.id == "kalshi", do: "Demo", else: "Paper")}
                      </span>
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
