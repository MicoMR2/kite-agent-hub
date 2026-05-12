defmodule KiteAgentHubWeb.ApiKeysLive do
  use KiteAgentHubWeb, :live_view

  require Logger

  alias KiteAgentHub.{Credentials, Orgs}

  # Paper slot = test trades, settles on Kite testnet (chain 2368).
  # Live slot = real money, settles on Kite mainnet (chain 2366).
  # Visual separation is a safety feature, not cosmetic — Mico
  # specifically asked for this so muscle-memory paste can't trigger
  # an accidental real-money order (msg 9168 / Phorari 9169).
  @paper_providers [
    %{
      id: "alpaca",
      label: "Alpaca (Paper)",
      hint: "Paper trading at paper-api.alpaca.markets. Test trades only — no real money.",
      key_label: "API Key ID",
      secret_label: "API Secret Key"
    },
    %{
      id: "kalshi",
      label: "Kalshi (Demo)",
      hint: "Demo trading at demo-api.kalshi.co. Test trades only — no real money.",
      key_label: "API Key ID",
      secret_label: "RSA Private Key (PEM)"
    },
    %{
      id: "oanda",
      label: "OANDA (Practice)",
      hint: "Practice account at api-fxpractice.oanda.com. Generate a Personal Access Token from My Account → Manage API Access.",
      key_label: "Display Name",
      secret_label: "Personal Access Token"
    }
  ]

  @live_providers [
    %{
      id: "alpaca_live",
      label: "Alpaca (Live)",
      hint: "Real-money account at api.alpaca.markets. Orders placed with this key move real funds.",
      key_label: "API Key ID",
      secret_label: "API Secret Key"
    },
    %{
      id: "kalshi_live",
      label: "Kalshi (Live)",
      hint: "Real-money account at api.elections.kalshi.com. Orders placed with this key move real funds.",
      key_label: "API Key ID",
      secret_label: "RSA Private Key (PEM)"
    },
    %{
      id: "oanda_live",
      label: "OANDA (Live)",
      hint: "Real-money account at api-fxtrade.oanda.com. Orders placed with this key move real funds.",
      key_label: "Display Name",
      secret_label: "Personal Access Token"
    },
    %{
      id: "polymarket",
      label: "Polymarket (Live)",
      hint: "Polymarket is live-money only — there is no paper / sandbox endpoint. Relayer credentials are stored; wallet signing happens client-side.",
      key_label: "Relayer Address (0x…)",
      secret_label: "Relayer API Key"
    }
  ]

  @providers @paper_providers ++ @live_providers

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    org =
      try do
        Orgs.get_org_for_user(user.id)
      rescue
        e ->
          Logger.error("ApiKeysLive mount: Orgs.get_org_for_user crashed: #{inspect(e)}")
          nil
      end

    configured =
      if org do
        try do
          Credentials.configured_providers(org.id)
        rescue
          e ->
            Logger.error("ApiKeysLive mount: configured_providers crashed: #{inspect(e)}")
            []
        end
      else
        []
      end

    credentials =
      if org do
        try do
          load_masked_credentials(org.id)
        rescue
          e ->
            Logger.error("ApiKeysLive mount: load_masked_credentials crashed: #{inspect(e)}")
            %{}
        end
      else
        %{}
      end

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:paper_providers, @paper_providers)
     |> assign(:live_providers, @live_providers)
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

    # Live-slot confirmation gate (CyberSec ask 5, msg 9176). Live
    # credentials require the unmissable "I understand this is real
    # money" checkbox on the form. The check is enforced here at the
    # handler — never trust the absence of the form field as a green
    # light, and never accept a live save without the affirmative
    # checkbox value.
    live_slot? = provider in KiteAgentHub.Credentials.ApiCredential.live_providers()
    confirmed? = Map.get(params, "live_confirm") in ["true", "on", true]

    # Cross-slot key-reuse guard (CyberSec asks 6 + 7, msg 9199).
    # When the pasted key_id matches the counterpart slot for the
    # same broker family (paper alpaca ↔ alpaca_live, etc.), require
    # a second explicit confirmation. Server-side enforced so the
    # client cannot bypass via DevTools.
    counterpart = counterpart_slug(provider)
    reuse_conflict? = key_collision?(org.id, counterpart, key_id)
    reuse_confirmed? = Map.get(params, "reuse_confirm") in ["true", "on", true]

    cond do
      live_slot? and not confirmed? ->
        {:noreply,
         socket
         |> assign(:form_errors, %{live_confirm: ["You must confirm this is real money before saving."]})
         |> put_flash(:error, "Live-money keys need the 'I understand' checkbox before they can save.")}

      reuse_conflict? and not reuse_confirmed? ->
        {:noreply,
         socket
         |> assign(:form_errors, %{
           reuse_confirm: [
             "This key_id matches the existing #{counterpart} slot. Confirm this is intentional (likely a paste mistake)."
           ]
         })
         |> put_flash(:error, "Same key_id is already saved on the counterpart slot. Confirm to proceed.")}

      true ->
        save_credential(socket, org, provider, key_id, secret, env, params)
    end
  end

  # Map a provider slug to its paper/live counterpart for cross-slot
  # reuse detection. Polymarket has no counterpart (live-only).
  defp counterpart_slug("alpaca"), do: "alpaca_live"
  defp counterpart_slug("alpaca_live"), do: "alpaca"
  defp counterpart_slug("kalshi"), do: "kalshi_live"
  defp counterpart_slug("kalshi_live"), do: "kalshi"
  defp counterpart_slug("oanda"), do: "oanda_live"
  defp counterpart_slug("oanda_live"), do: "oanda"
  defp counterpart_slug(_), do: nil

  defp key_collision?(_org_id, nil, _key_id), do: false
  defp key_collision?(_org_id, _counterpart, key_id) when key_id in [nil, ""], do: false

  defp key_collision?(org_id, counterpart, key_id) when is_binary(key_id) do
    case Credentials.get_credential(org_id, counterpart) do
      %{key_id: ^key_id} -> true
      _ -> false
    end
  end

  defp save_credential(socket, org, provider, key_id, secret, env, params) do

    attrs =
      %{
        "key_id" => key_id,
        "secret" => secret,
        "env" => env
      }
      |> maybe_put(params, "account_id")
      |> maybe_put(params, "server")

    actor_user_id = socket.assigns.current_scope && socket.assigns.current_scope.user && socket.assigns.current_scope.user.id

    result =
      try do
        Credentials.upsert_credential(org.id, provider, attrs, actor_user_id)
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      end

    case result do
      {:ok, _} ->
        configured = safe_configured(org.id)
        credentials = safe_load_masked(org.id)

        {:noreply,
         socket
         |> assign(:configured, configured)
         |> assign(:credentials, credentials)
         |> assign(:editing, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "#{String.capitalize(provider)} credentials saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
        {:noreply, assign(socket, :form_errors, errors)}

      {:error, _other} ->
        {:noreply, put_flash(socket, :error, "Could not save credentials. Please try again.")}
    end
  end

  def handle_event("delete", %{"provider" => provider}, socket) do
    org = socket.assigns.org

    actor_user_id = socket.assigns.current_scope && socket.assigns.current_scope.user && socket.assigns.current_scope.user.id

    try do
      Credentials.delete_credential(org.id, provider, actor_user_id)
    rescue
      e ->
        Logger.error("ApiKeysLive: delete_credential crashed: #{inspect(e)}")
        :ok
    end

    configured = safe_configured(org.id)
    credentials = safe_load_masked(org.id)

    {:noreply,
     socket
     |> assign(:configured, configured)
     |> assign(:credentials, credentials)
     |> put_flash(:info, "#{String.capitalize(provider)} credentials removed.")}
  end

  defp load_masked_credentials(org_id) do
    ~w(alpaca alpaca_live kalshi kalshi_live polymarket oanda oanda_live)
    |> Enum.reduce(%{}, fn provider, acc ->
      case Credentials.get_credential(org_id, provider) do
        nil ->
          acc

        cred ->
          Map.put(acc, provider, %{
            key_id: Credentials.mask_key_id(cred.key_id),
            env: cred.env || "paper",
            server: Map.get(cred, :server),
            account_id: Map.get(cred, :account_id)
          })
      end
    end)
  end

  defp maybe_put(attrs, params, key) do
    case Map.get(params, key) do
      nil -> attrs
      "" -> attrs
      v -> Map.put(attrs, key, v)
    end
  end

  defp safe_configured(org_id) do
    try do
      Credentials.configured_providers(org_id)
    rescue
      e ->
        Logger.error("ApiKeysLive: configured_providers crashed: #{inspect(e)}")
        []
    end
  end

  defp safe_load_masked(org_id) do
    try do
      load_masked_credentials(org_id)
    rescue
      e ->
        Logger.error("ApiKeysLive: load_masked_credentials crashed: #{inspect(e)}")
        %{}
    end
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

          <%!-- Paper / Sandbox section: test trades only, settles on Kite testnet. --%>
          <div class="rounded-2xl border border-emerald-500/20 bg-emerald-500/[0.02] p-4">
            <h3 class="text-[11px] font-black text-emerald-300 uppercase tracking-widest">
              Paper / Sandbox — test trades only
            </h3>
            <p class="text-[11px] text-gray-500 mt-0.5">
              Keys saved in this section route to each broker's sandbox endpoint. Settles on Kite testnet (chain 2368).
            </p>
          </div>

          <%!-- Provider API Keys --%>
          <%= for provider <- @paper_providers do %>
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
                      placeholder={
                        if provider.id in ["oanda", "oanda_live"],
                          do: "e.g. My Practice Account",
                          else: "Paste your key ID..."
                      }
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                    />
                    <%= if provider.id in ["oanda", "oanda_live"] do %>
                      <p class="text-[10px] text-gray-500 mt-1">Display name only — not sent to OANDA.</p>
                    <% end %>
                    <%= if err = get_in(@form_errors, [:key_id, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      {provider.secret_label}
                    </label>
                    <%= if provider.id in ["polymarket", "oanda", "oanda_live"] do %>
                      <input
                        type="password"
                        name="secret"
                        autocomplete="off"
                        placeholder={
                          case provider.id do
                            "oanda" -> "Paste your OANDA practice access token..."
                            "oanda_live" -> "Paste your OANDA LIVE access token..."
                            _ -> "Paste your Relayer API key..."
                          end
                        }
                        class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                      />
                    <% else %>
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
                    <% end %>
                    <%= if err = get_in(@form_errors, [:secret, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <%= if provider.id in ["oanda", "oanda_live"] do %>
                    <%= if provider.id == "oanda_live" do %>
                      <div class="rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 text-xs text-red-200 font-bold">
                        ⚠ LIVE MONEY — Orders placed with this key execute against your real OANDA account.
                      </div>
                    <% end %>
                    <div>
                      <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                        Account ID
                      </label>
                      <input
                        type="text"
                        name="account_id"
                        autocomplete="off"
                        value={(existing && existing.account_id) || ""}
                        placeholder="001-001-1234567-001"
                        class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                      />
                      <%= if err = get_in(@form_errors, [:account_id, Access.at(0)]) do %>
                        <p class="text-xs text-red-400 mt-1">{err}</p>
                      <% end %>
                    </div>
                  <% end %>

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

          <%!-- Live (Real Money) section: distinct visual separation per Mico 9168 / Phorari 9169. --%>
          <div class="rounded-2xl border border-red-500/40 bg-red-500/[0.04] p-4 mt-4">
            <h3 class="text-[11px] font-black text-red-300 uppercase tracking-widest">
              ⚠ Live · Real money
            </h3>
            <p class="text-[11px] text-red-200/80 mt-0.5">
              Keys saved in this section connect to a funded brokerage account. Orders placed against these keys move real funds and settle on Kite mainnet (chain 2366).
            </p>
          </div>

          <%= for provider <- @live_providers do %>
            <% configured = provider.id in @configured %>
            <% existing = Map.get(@credentials, provider.id) %>
            <div class="rounded-2xl border border-red-500/30 bg-red-500/[0.025] backdrop-blur-md p-6">
              <div class="flex items-center justify-between mb-4">
                <div>
                  <h2 class="text-sm font-black text-white uppercase tracking-widest">
                    {provider.label}
                  </h2>
                  <p class="text-xs text-gray-400 mt-0.5">{provider.hint}</p>
                </div>
                <div class="flex items-center gap-2">
                  <%= if configured do %>
                    <span class="flex items-center gap-1.5 text-[10px] font-bold uppercase tracking-widest text-red-300">
                      <span class="w-1.5 h-1.5 rounded-full bg-red-400 shadow-[0_0_6px_#ef4444]"></span>
                      Live · connected
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
                  <input type="hidden" name="env" value="live" />

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      {provider.key_label}
                    </label>
                    <input
                      type="text"
                      name="key_id"
                      autocomplete="off"
                      placeholder="Paste your LIVE key ID..."
                      class="w-full bg-black/40 border border-red-500/30 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-red-400 font-mono"
                    />
                    <%= if err = get_in(@form_errors, [:key_id, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      {provider.secret_label}
                    </label>
                    <%= if provider.id == "kalshi_live" do %>
                      <textarea
                        name="secret"
                        autocomplete="off"
                        rows="6"
                        placeholder="-----BEGIN RSA PRIVATE KEY-----..."
                        class="w-full bg-black/40 border border-red-500/30 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-red-400 font-mono resize-none"
                      ></textarea>
                    <% else %>
                      <input
                        type="password"
                        name="secret"
                        autocomplete="off"
                        placeholder="Paste your LIVE secret..."
                        class="w-full bg-black/40 border border-red-500/30 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-red-400 font-mono"
                      />
                    <% end %>
                    <%= if err = get_in(@form_errors, [:secret, Access.at(0)]) do %>
                      <p class="text-xs text-red-400 mt-1">{err}</p>
                    <% end %>
                  </div>

                  <%= if provider.id == "oanda_live" do %>
                    <div>
                      <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                        Account ID
                      </label>
                      <input
                        type="text"
                        name="account_id"
                        autocomplete="off"
                        value={(existing && existing.account_id) || ""}
                        placeholder="001-001-1234567-001"
                        class="w-full bg-black/40 border border-red-500/30 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-red-400 font-mono"
                      />
                    </div>
                  <% end %>

                  <%!-- Live-slot confirmation (CyberSec ask 5, msg 9176). Required before save. --%>
                  <label class="flex items-start gap-3 rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 cursor-pointer">
                    <input type="checkbox" name="live_confirm" value="true" class="mt-0.5" />
                    <span class="text-xs text-red-100 leading-relaxed">
                      <strong class="font-bold">I understand this is real money.</strong> Orders placed with this key will execute against a funded brokerage account and move real funds. There is no paper-trading fallback once this key is wired up.
                    </span>
                  </label>
                  <%= if err = get_in(@form_errors, [:live_confirm, Access.at(0)]) do %>
                    <p class="text-xs text-red-400">{err}</p>
                  <% end %>

                  <%!-- Cross-slot key-reuse confirmation (CyberSec ask 7, msg 9199).
                       Only rendered after the server has detected a key_id collision
                       with the paper counterpart; the field is otherwise harmless to
                       include unconditionally since the server-side check is what
                       gates the save. --%>
                  <%= if get_in(@form_errors, [:reuse_confirm, Access.at(0)]) do %>
                    <label class="flex items-start gap-3 rounded-xl border border-amber-500/40 bg-amber-500/10 px-4 py-3 cursor-pointer">
                      <input type="checkbox" name="reuse_confirm" value="true" class="mt-0.5" />
                      <span class="text-xs text-amber-100 leading-relaxed">
                        <strong class="font-bold">This key matches my paper / sandbox slot.</strong> I am intentionally using the same key_id for live trading and this is not a paste mistake.
                      </span>
                    </label>
                    <p class="text-xs text-amber-300">{get_in(@form_errors, [:reuse_confirm, Access.at(0)])}</p>
                  <% end %>

                  <div class="flex items-center gap-3 pt-1">
                    <button
                      type="submit"
                      class="px-5 py-2 rounded-xl bg-red-500 text-white text-xs font-black uppercase tracking-widest hover:bg-red-600 transition-colors"
                    >
                      Save live key
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
                      <span class="text-[10px] font-black uppercase tracking-widest px-2 py-0.5 rounded border text-red-300 border-red-500/40 bg-red-500/15">
                        Live
                      </span>
                    <% else %>
                      <span class="text-gray-700 italic text-xs">No live key stored</span>
                    <% end %>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="edit"
                      phx-value-provider={provider.id}
                      class="px-4 py-1.5 rounded-xl border border-red-500/30 text-xs font-bold uppercase tracking-widest text-red-300 hover:text-red-100 hover:border-red-400 transition-all"
                    >
                      {if configured, do: "Update", else: "Add live key"}
                    </button>
                    <%= if configured do %>
                      <button
                        phx-click="delete"
                        phx-value-provider={provider.id}
                        data-confirm={"Remove live #{provider.label} credentials?"}
                        class="px-4 py-1.5 rounded-xl border border-red-500/30 text-xs font-bold uppercase tracking-widest text-red-400 hover:bg-red-500/10 transition-all"
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
