defmodule KiteAgentHubWeb.AgentsLive do
  @moduledoc """
  Settings > Agents tab. Lists every agent in the current user's org,
  plus inline edit (name/tags/bio), API-token rotation (shown once),
  and archive (soft-delete with cascade-cancel of open trades) —
  Phorari PR msg 6341, PR-B of the split agreed in msg 6347.

  All mutations flow through `KiteAgentHub.Trading` (backed by the
  API controller from PR-A) so the same RLS + whitelist enforcement
  covers both the LiveView and the REST surface.
  """
  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.{Orgs, Repo, Trading}
  alias KiteAgentHub.Kite.{ChainId, VaultConfig}
  alias KiteAgentHub.Passport.Passports
  alias KiteAgentHub.Trading.KiteAgent

  # Soft rate-limit on chain_id flips per agent (CyberSec ask 9, msg
  # 9212). Server-side timestamp check in :ets — no DB column, no
  # new infra. The :kah_chain_flip_cooldown table is created lazily
  # on the first flip.
  @chain_flip_cooldown_ms 60_000
  @chain_flip_table :kah_chain_flip_cooldown

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    # Mount hardening (kah_lv_rescue): every DB call must rescue, or
    # a transient `DBConnection.ConnectionError` during a pool burst
    # crashes the LV process and Phoenix mount-loops the user.
    {org, agents, passport_links} =
      try do
        org = Orgs.get_org_for_user(user.id)
        agents = if org, do: Trading.list_agents(org.id), else: []
        passport_links = Passports.active_links_by_agent(agents)
        {org, agents, passport_links}
      rescue
        e ->
          require Logger
          Logger.warning("AgentsLive mount DB read failed — #{Exception.message(e)}")
          {nil, [], %{}}
      end

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:agents, agents)
     |> assign(:editing_id, nil)
     |> assign(:form_errors, %{})
     |> assign(:revealed_token, nil)
     |> assign(:confirm_archive_id, nil)
     |> assign(:passport_links, passport_links)
     |> assign(:passport_form_errors, %{})
     |> assign(:expanded_passport_id, nil)
     |> assign(:vault_address, VaultConfig.address())}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, assign(socket, editing_id: id, form_errors: %{})}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing_id: nil, form_errors: %{})}
  end

  def handle_event("save", %{"agent_id" => id} = params, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))

    attestations_enabled? = params["attestations_enabled"] in ["true", "on", true]

    attrs = %{
      "name" => params["name"],
      "bio" => params["bio"],
      "tags" => parse_tags(params["tags"]),
      "wallet_address" => params["wallet_address"],
      "attestations_enabled" => attestations_enabled?
    }

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.update_agent_profile(agent, attrs)
         end) do
      {:ok, {:ok, updated}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, updated))
         |> assign(:editing_id, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Agent updated.")}

      {:ok, {:error, changeset}} ->
        {:noreply, assign(socket, :form_errors, errors_of(changeset))}
    end
  end

  def handle_event("save_risk_config", %{"agent_id" => id} = params, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))
    raw = params["risk_config"] || %{}

    # Strip blank strings so the form's "leave blank to use default"
    # behavior translates to "no override on this key" rather than
    # "user explicitly submitted empty".
    sanitized =
      raw
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Map.new(fn
        {k, "true"} -> {k, true}
        {k, "false"} -> {k, false}
        {k, "on"} -> {k, true}
        {k, v} -> {k, v}
      end)

    actor_id = socket.assigns.current_scope.user.id

    case Repo.with_user(actor_id, fn ->
           Trading.update_agent_risk_config(agent, %{"risk_config" => sanitized}, actor_id)
         end) do
      {:ok, {:ok, updated}} ->
        :telemetry.execute(
          [:kah, :risk_config, :saved],
          %{count: 1},
          %{agent_id: updated.id, outcome: :ok}
        )

        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, updated))
         |> assign(:editing_id, nil)
         |> assign(:form_errors, %{})
         |> put_flash(:info, "Risk limits updated.")}

      {:ok, {:error, %Ecto.Changeset{} = cs}} ->
        :telemetry.execute(
          [:kah, :risk_config, :saved],
          %{count: 1},
          %{agent_id: agent.id, outcome: :invalid}
        )

        {:noreply, assign(socket, :form_errors, errors_of(cs))}

      {:ok, {:error, _other}} ->
        {:noreply, put_flash(socket, :error, "Could not update risk limits.")}
    end
  end

  def handle_event("rotate_token", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.rotate_agent_api_token(agent)
         end) do
      {:ok, {:ok, updated}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, updated))
         |> assign(:revealed_token, %{id: updated.id, token: updated.api_token})
         |> put_flash(:info, "API token rotated. Copy it now — it won't be shown again.")}

      {:ok, {:error, _}} ->
        {:noreply, put_flash(socket, :error, "Token rotation failed.")}
    end
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, revealed_token: nil)}
  end

  def handle_event("confirm_archive", %{"id" => id}, socket) do
    {:noreply, assign(socket, confirm_archive_id: id)}
  end

  def handle_event("cancel_archive", _params, socket) do
    {:noreply, assign(socket, confirm_archive_id: nil)}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    agent = Enum.find(socket.assigns.agents, &(&1.id == id))

    case Repo.with_user(socket.assigns.current_scope.user.id, fn ->
           Trading.archive_agent(agent)
         end) do
      {:ok, {:ok, %{agent: archived, cancelled_count: n}}} ->
        {:noreply,
         socket
         |> assign(:agents, replace_agent(socket.assigns.agents, archived))
         |> assign(:confirm_archive_id, nil)
         |> put_flash(
           :info,
           "#{archived.name} archived. #{n} open trade(s) auto-cancelled."
         )}

      {:ok, {:error, _}} ->
        {:noreply,
         socket
         |> assign(:confirm_archive_id, nil)
         |> put_flash(:error, "Archive failed.")}
    end
  end

  # Toggle the Passport panel open/closed for a given agent.
  def handle_event("toggle_passport_panel", %{"id" => id}, socket) do
    next = if socket.assigns.expanded_passport_id == id, do: nil, else: id
    {:noreply, assign(socket, expanded_passport_id: next, passport_form_errors: %{})}
  end

  def handle_event("link_passport", %{"agent_id" => id} = params, socket) do
    with %KiteAgent{} = agent <- find_owned_agent(socket, id),
         attrs <- %{
           "passport_user_id" => params["passport_user_id"],
           "passport_agent_id" => params["passport_agent_id"],
           "passport_wallet_address" => params["passport_wallet_address"]
         },
         {:ok, link} <-
           Passports.link_agent(socket.assigns.current_scope.user.id, agent, attrs) do
      {:noreply,
       socket
       |> assign(:passport_links, Map.put(socket.assigns.passport_links, agent.id, link))
       |> assign(:passport_form_errors, %{})
       |> put_flash(:info, "Passport linked.")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Agent not found.")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, :passport_form_errors, errors_of(cs))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not link Passport.")}
    end
  end

  def handle_event("unlink_passport", %{"agent_id" => id}, socket) do
    link = Map.get(socket.assigns.passport_links, id)

    with %KiteAgent{} <- find_owned_agent(socket, id),
         %_{} <- link,
         {:ok, _} <- Passports.unlink_agent(socket.assigns.current_scope.user.id, link) do
      {:noreply,
       socket
       |> assign(:passport_links, Map.delete(socket.assigns.passport_links, id))
       |> put_flash(:info, "Passport unlinked.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Could not unlink Passport.")}
    end
  end

  def handle_event("select_payment_rail", %{"agent_id" => id, "rail" => rail}, socket) do
    rails = KiteAgent.payment_rails()

    with true <- rail in rails,
         %KiteAgent{} = agent <- find_owned_agent(socket, id),
         {:ok, updated} <-
           Passports.change_payment_rail(socket.assigns.current_scope.user.id, agent, rail) do
      {:noreply,
       socket
       |> assign(:agents, replace_agent(socket.assigns.agents, updated))
       |> put_flash(:info, "Payment rail updated.")}
    else
      false ->
        {:noreply, put_flash(socket, :error, "Invalid payment rail.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update payment rail.")}
    end
  end

  def handle_event("select_chain", %{"agent_id" => id} = params, socket) do
    chain_id =
      case params["chain_id"] do
        n when is_integer(n) -> n
        s when is_binary(s) -> case Integer.parse(s), do: ({n, ""} -> n; _ -> nil)
        _ -> nil
      end

    valid_chains = ChainId.valid_chain_ids()
    mainnet = ChainId.mainnet()
    actor_user_id = socket.assigns.current_scope.user.id

    with %KiteAgent{} = agent <- find_owned_agent(socket, id),
         true <- chain_id in valid_chains,
         :ok <- check_cooldown(agent.id),
         :ok <- check_mainnet_gate(chain_id, params, mainnet),
         {:ok, updated} <-
           Trading.update_agent_chain(agent, %{"chain_id" => chain_id}, actor_user_id) do
      record_flip(updated.id)

      flash_msg =
        cond do
          agent.chain_id == updated.chain_id ->
            "Chain unchanged."

          updated.chain_id == mainnet ->
            "Switched to Mainnet. " <> open_position_warning(agent) <> passport_warning(agent)

          true ->
            "Switched to Testnet. " <> open_position_warning(agent) <> passport_warning(agent)
        end

      {:noreply,
       socket
       |> assign(:agents, replace_agent(socket.assigns.agents, updated))
       |> put_flash(:info, flash_msg)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Agent not found.")}

      false ->
        {:noreply, put_flash(socket, :error, "Invalid chain id.")}

      {:error, :mainnet_unavailable} ->
        {:noreply,
         put_flash(socket, :error, "Mainnet is not available on this instance (operator must set AGENT_PRIVATE_KEY_MAINNET).")}

      {:error, :mainnet_confirmation_required} ->
        {:noreply,
         put_flash(socket, :error, "Switching to Mainnet requires the confirmation checkbox.")}

      {:error, :cooldown} ->
        {:noreply, put_flash(socket, :error, "Chain switches are rate-limited to one per minute per agent. Try again shortly.")}

      {:error, %Ecto.Changeset{} = cs} ->
        require Logger

        Logger.error(
          "AgentsLive select_chain failed agent_id=#{id} chain_id=#{chain_id} errors=#{inspect(cs.errors)}"
        )

        {:noreply, put_flash(socket, :error, "Could not update chain.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not update chain.")}
    end
  end

  # CyberSec ask 2, msg 9212: server-side check that
  # AGENT_PRIVATE_KEY_MAINNET is set AND that the user ticked the
  # live-confirmation checkbox before allowing a mainnet flip. Both
  # gates run BEFORE Repo.update.
  defp check_mainnet_gate(chain_id, params, mainnet) do
    cond do
      chain_id != mainnet -> :ok
      not ChainId.mainnet_available?() -> {:error, :mainnet_unavailable}
      not (Map.get(params, "mainnet_confirm") in ["true", "on", true]) ->
        {:error, :mainnet_confirmation_required}
      true -> :ok
    end
  end

  # CyberSec ask 9, msg 9212: 1 flip/min/agent soft rate limit.
  # ETS-backed; the table is lazily created on first call and lives
  # for the lifetime of the BEAM process. A reject returns
  # {:error, :cooldown} so the LV surface flashes instead of raising.
  defp check_cooldown(agent_id) do
    ensure_cooldown_table()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@chain_flip_table, agent_id) do
      [{^agent_id, ts}] when now - ts < @chain_flip_cooldown_ms -> {:error, :cooldown}
      _ -> :ok
    end
  end

  defp record_flip(agent_id) do
    ensure_cooldown_table()
    :ets.insert(@chain_flip_table, {agent_id, System.monotonic_time(:millisecond)})
  end

  defp ensure_cooldown_table do
    case :ets.whereis(@chain_flip_table) do
      :undefined ->
        try do
          :ets.new(@chain_flip_table, [:named_table, :public, :set, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp open_position_warning(agent) do
    case Trading.count_open_trades(agent.id) do
      n when is_integer(n) and n > 0 ->
        "Note: #{n} open position(s) were NOT auto-closed on the broker — close manually if needed. "

      _ ->
        ""
    end
  end

  defp passport_warning(agent) do
    case Passports.get_active_link(agent.id) do
      nil -> ""
      _ -> "Note: this agent has an active Passport link — the wallet may be chain-specific; unlink + relink if needed."
    end
  end

  # Belt-and-suspenders ownership check (CyberSec ask 5, msg 9093). The
  # context wraps writes in `Repo.with_user/2` so RLS scopes them, but
  # we also explicitly verify the agent lives in the current user's
  # org_id before invoking the context — defense in depth against any
  # future RLS-policy regression.
  defp find_owned_agent(socket, id) do
    org_id = socket.assigns.org && socket.assigns.org.id

    case Enum.find(socket.assigns.agents, &(&1.id == id)) do
      %KiteAgent{organization_id: ^org_id} = agent when not is_nil(org_id) -> agent
      _ -> nil
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp parse_tags(nil), do: []

  defp parse_tags(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(other) when is_list(other), do: other
  defp parse_tags(_), do: []

  defp replace_agent(agents, updated) do
    Enum.map(agents, fn a -> if a.id == updated.id, do: updated, else: a end)
  end

  defp errors_of(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, k ->
        opts |> Keyword.get(String.to_existing_atom(k), k) |> to_string()
      end)
    end)
  end

  # Read the persisted risk_config (string keys) for form pre-fill.
  # Returns "" for any unset key so the input renders blank — meaning
  # "use module default", not "force this value".
  defp risk_value(%{} = cfg, key), do: Map.get(cfg, key, "") |> to_string()

  attr :agent, :map, required: true
  attr :form_errors, :map, default: %{}

  defp risk_limits_form(assigns) do
    ~H"""
    <form phx-submit="save_risk_config" class="mt-6 pt-6 border-t border-white/5 space-y-4">
      <input type="hidden" name="agent_id" value={@agent.id} />

      <div class="flex items-baseline justify-between">
        <h4 class="text-[11px] font-black uppercase tracking-widest text-white">Risk Limits</h4>
        <p class="text-[10px] text-gray-500">Leave blank to use the workspace default.</p>
      </div>

      <p class="text-[10px] text-amber-400/80">
        Saved values are persisted but not yet enforced at trade time —
        runtime gate ships in PR #297. Until then the workspace default
        is what actually caps trades.
      </p>

      <p
        :if={err = get_in(@form_errors, [:risk_config, Access.at(0)])}
        class="text-xs text-red-400"
      >
        {err}
      </p>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
            Per-trade notional cap (USD)
          </label>
          <input
            type="number"
            step="0.01"
            min="0"
            max="5000"
            name="risk_config[per_trade_notional_cap_usd]"
            value={risk_value(@agent.risk_config || %{}, "per_trade_notional_cap_usd")}
            placeholder="default 5000"
            class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
          />
          <p class="text-[10px] text-gray-600 mt-1">Hard server ceiling: $5,000.</p>
        </div>

        <div>
          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
            Profit-trim partial (%)
          </label>
          <input
            type="number"
            step="1"
            min="0"
            max="100"
            name="risk_config[profit_trim_partial_pct]"
            value={risk_value(@agent.risk_config || %{}, "profit_trim_partial_pct")}
            placeholder="default 3"
            class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
          />
        </div>

        <div>
          <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
            Profit-trim full (%)
          </label>
          <input
            type="number"
            step="1"
            min="0"
            max="100"
            name="risk_config[profit_trim_full_pct]"
            value={risk_value(@agent.risk_config || %{}, "profit_trim_full_pct")}
            placeholder="default 5"
            class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
          />
          <p class="text-[10px] text-gray-600 mt-1">Must be greater than partial.</p>
        </div>

        <div>
          <label class="flex items-center gap-2 mt-6 sm:mt-7">
            <input
              type="checkbox"
              name="risk_config[market_hours_only]"
              value="true"
              checked={
                Map.get(@agent.risk_config || %{}, "market_hours_only", true) in [true, "true"]
              }
              class="h-4 w-4 rounded border-white/20 bg-black/40"
            />
            <span class="text-xs text-gray-300">Market-hours only (equities/options)</span>
          </label>
        </div>
      </div>

      <div :if={@agent.agent_type == "trading"} class="pt-2">
        <label class="flex items-start gap-2">
          <input
            type="checkbox"
            name="risk_config[auto_exit_enabled]"
            value="true"
            checked={
              Map.get(@agent.risk_config || %{}, "auto_exit_enabled", false) in [true, "true"]
            }
            class="h-4 w-4 mt-0.5 rounded border-white/20 bg-black/40"
          />
          <span class="text-xs text-gray-300">
            Auto-exit on low QRB score (rule-based)
            <span class="block text-[10px] text-gray-600 mt-0.5">
              Off by default. When on, the agent automatically issues exits on positions whose composite score falls below the adaptive threshold every tick. Trading agents only.
            </span>
          </span>
        </label>
      </div>

      <button
        type="submit"
        class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100"
      >
        Save Risk Limits
      </button>
    </form>
    """
  end

  # ── Render ────────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="min-h-screen bg-[#0a0a0f] text-white">
        <KiteAgentHubWeb.SettingsNav.render active={:agents} />

        <div class="max-w-3xl mx-auto px-4 sm:px-6 lg:px-8 py-10 space-y-6">
          <div class="flex items-center justify-between">
            <div>
              <h2 class="text-sm font-black text-white uppercase tracking-widest">Agents</h2>
              <p class="text-xs text-gray-500 mt-0.5">
                Manage every agent in {(@org && @org.name) || "your workspace"} — edit profile, rotate API tokens, archive.
              </p>
            </div>
            <.link
              navigate={~p"/agents/new"}
              class="px-4 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100 transition-colors"
            >
              New Agent
            </.link>
          </div>

          <%= if @revealed_token do %>
            <div class="rounded-2xl border border-emerald-500/40 bg-emerald-500/5 p-5 space-y-2">
              <div class="flex items-center justify-between">
                <h3 class="text-xs font-black text-emerald-300 uppercase tracking-widest">
                  New API Token — copy it now
                </h3>
                <button
                  phx-click="dismiss_token"
                  class="text-[10px] font-bold uppercase tracking-widest text-gray-500 hover:text-white"
                >
                  Dismiss
                </button>
              </div>
              <p class="text-[11px] text-gray-400">
                This token is shown only once. Replace it in any scripts/clients using the previous token.
              </p>
              <code class="block font-mono text-xs text-emerald-200 break-all bg-black/40 rounded-xl p-3">
                {@revealed_token.token}
              </code>
            </div>
          <% end %>

          <%= if @agents == [] do %>
            <div class="rounded-2xl border border-white/10 bg-white/[0.02] p-8 text-center">
              <p class="text-sm text-gray-500">
                No agents yet. Create one from the button above.
              </p>
            </div>
          <% end %>

          <div
            :for={agent <- @agents}
            class="rounded-2xl border border-white/10 bg-white/[0.02] backdrop-blur-md p-6"
          >
            <%= if @editing_id == agent.id do %>
              <form phx-submit="save" class="space-y-4">
                <input type="hidden" name="agent_id" value={agent.id} />

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Name
                  </label>
                  <input
                    type="text"
                    name="name"
                    value={agent.name}
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white focus:outline-none focus:border-white/30"
                  />
                  <p
                    :if={err = get_in(@form_errors, [:name, Access.at(0)])}
                    class="text-xs text-red-400 mt-1"
                  >
                    {err}
                  </p>
                </div>

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Tags
                    <span class="text-gray-600 normal-case tracking-normal">(comma-separated)</span>
                  </label>
                  <input
                    type="text"
                    name="tags"
                    value={Enum.join(agent.tags || [], ", ")}
                    placeholder="momentum, equities"
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
                  />
                  <p
                    :if={err = get_in(@form_errors, [:tags, Access.at(0)])}
                    class="text-xs text-red-400 mt-1"
                  >
                    {err}
                  </p>
                </div>

                <div>
                  <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                    Bio
                  </label>
                  <textarea
                    name="bio"
                    rows="3"
                    class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-sm text-white placeholder-gray-600 focus:outline-none focus:border-white/30 resize-none"
                  >{agent.bio}</textarea>
                  <p
                    :if={err = get_in(@form_errors, [:bio, Access.at(0)])}
                    class="text-xs text-red-400 mt-1"
                  >
                    {err}
                  </p>
                </div>

                <div class="rounded-xl border border-white/10 bg-white/[0.02] p-4 space-y-3">
                  <label class="flex items-start gap-3 cursor-pointer">
                    <input
                      type="checkbox"
                      name="attestations_enabled"
                      value="true"
                      checked={agent.attestations_enabled}
                      class="mt-1 w-4 h-4 rounded border-white/20 bg-black/40"
                    />
                    <div class="flex-1">
                      <p class="text-sm font-bold text-white">Enable Kite chain attestations</p>
                      <p class="text-[11px] text-gray-500 mt-0.5 leading-relaxed">
                        Off by default. When on, every settled trade is recorded on-chain via your wallet. Requires a valid wallet address below.
                      </p>
                    </div>
                  </label>

                  <div>
                    <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1.5">
                      Wallet Address
                      <span class="text-gray-600 normal-case tracking-normal">
                        (optional unless attestations are on)
                      </span>
                    </label>
                    <input
                      type="text"
                      name="wallet_address"
                      value={agent.wallet_address}
                      placeholder="0x..."
                      spellcheck="false"
                      class="w-full bg-black/40 border border-white/10 rounded-xl px-4 py-3 text-xs text-white placeholder-gray-600 focus:outline-none focus:border-white/30 font-mono"
                    />
                    <p
                      :if={err = get_in(@form_errors, [:wallet_address, Access.at(0)])}
                      class="text-xs text-red-400 mt-1"
                    >
                      {err}
                    </p>
                  </div>
                </div>

                <div class="flex items-center gap-3">
                  <button
                    type="submit"
                    class="px-5 py-2 rounded-xl bg-white text-black text-xs font-black uppercase tracking-widest hover:bg-gray-100"
                  >
                    Save
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_edit"
                    class="px-5 py-2 rounded-xl border border-white/10 text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                  >
                    Cancel
                  </button>
                </div>
              </form>

              <.risk_limits_form
                agent={agent}
                form_errors={@form_errors}
              />
            <% else %>
              <div class="space-y-3">
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <h3 class="text-sm font-black text-white truncate">{agent.name}</h3>
                      <span class={[
                        "text-[10px] font-bold uppercase tracking-widest px-2 py-0.5 rounded-full",
                        agent.status == "active" && "bg-emerald-500/10 text-emerald-400",
                        agent.status == "paused" && "bg-yellow-500/10 text-yellow-400",
                        agent.status == "archived" && "bg-gray-500/10 text-gray-500",
                        agent.status == "error" && "bg-red-500/10 text-red-400",
                        agent.status == "pending" && "bg-blue-500/10 text-blue-400"
                      ]}>
                        {agent.status}
                      </span>
                      <span class="text-[10px] font-bold uppercase tracking-widest text-gray-600">
                        {agent.agent_type}
                      </span>
                    </div>
                    <p class="text-[11px] text-gray-500 mt-0.5">
                      Workspace: {(@org && @org.name) || "—"}
                    </p>
                    <p :if={agent.bio} class="text-xs text-gray-400 mt-2">{agent.bio}</p>
                    <div :if={agent.tags && agent.tags != []} class="flex flex-wrap gap-1 mt-2">
                      <span
                        :for={tag <- agent.tags}
                        class="text-[10px] font-bold uppercase tracking-widest bg-white/5 border border-white/10 rounded-full px-2 py-0.5 text-gray-300"
                      >
                        {tag}
                      </span>
                    </div>
                  </div>
                  <div class="flex flex-col gap-1.5 shrink-0">
                    <button
                      :if={agent.status != "archived"}
                      phx-click="edit"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Edit
                    </button>
                    <button
                      :if={agent.status != "archived"}
                      phx-click="rotate_token"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Rotate Token
                    </button>
                    <button
                      :if={agent.status != "archived"}
                      phx-click="confirm_archive"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-red-500/30 text-[10px] font-bold uppercase tracking-widest text-red-400 hover:bg-red-500/10"
                    >
                      Archive
                    </button>
                  </div>
                </div>

                <div class="grid grid-cols-2 gap-3 pt-3 border-t border-white/5 text-[11px]">
                  <div>
                    <span class="block text-[10px] font-bold text-gray-600 uppercase tracking-widest">
                      Wallet
                    </span>
                    <span class={[
                      "font-mono truncate block",
                      agent.wallet_address && "text-gray-400",
                      !agent.wallet_address && agent.agent_type == "trading" && "text-yellow-500",
                      !agent.wallet_address && agent.agent_type != "trading" && "text-gray-600"
                    ]}>
                      <%= cond do %>
                        <% agent.wallet_address -> %>
                          {agent.wallet_address}
                        <% agent.agent_type == "trading" -> %>
                          trading disabled — wallet not configured
                        <% true -> %>
                          n/a (non-trading agent)
                      <% end %>
                    </span>
                  </div>
                  <div>
                    <span class="block text-[10px] font-bold text-gray-600 uppercase tracking-widest">
                      Vault
                    </span>
                    <span class="font-mono truncate block text-gray-400">
                      {agent.vault_address || "—"}
                    </span>
                  </div>
                </div>

                <div class="mt-4 pt-4 border-t border-white/5 space-y-3">
                  <div class="flex items-center justify-between">
                    <div>
                      <span class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                        Passport · Payment rail
                      </span>
                      <span class="text-[11px] text-gray-500">
                        Choose how this agent pays for KAH (post-hackathon).
                      </span>
                    </div>
                    <button
                      phx-click="toggle_passport_panel"
                      phx-value-id={agent.id}
                      class="px-3 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      {if @expanded_passport_id == agent.id, do: "Hide", else: "Configure"}
                    </button>
                  </div>

                  <div :if={@expanded_passport_id == agent.id} class="space-y-4">
                    <%!-- Payment rail selector --%>
                    <div class="grid grid-cols-3 gap-2">
                      <button
                        type="button"
                        phx-click="select_payment_rail"
                        phx-value-agent_id={agent.id}
                        phx-value-rail="none"
                        class={[
                          "px-3 py-2 rounded-xl border text-[10px] font-bold uppercase tracking-widest",
                          agent.payment_rail == "none" &&
                            "border-emerald-400 bg-emerald-500/10 text-emerald-200",
                          agent.payment_rail != "none" &&
                            "border-white/10 text-gray-400 hover:text-white hover:border-white/20"
                        ]}
                      >
                        None
                      </button>
                      <button
                        type="button"
                        phx-click="select_payment_rail"
                        phx-value-agent_id={agent.id}
                        phx-value-rail="per_trade"
                        class={[
                          "px-3 py-2 rounded-xl border text-[10px] font-bold uppercase tracking-widest",
                          agent.payment_rail == "per_trade" &&
                            "border-emerald-400 bg-emerald-500/10 text-emerald-200",
                          agent.payment_rail != "per_trade" &&
                            "border-white/10 text-gray-400 hover:text-white hover:border-white/20"
                        ]}
                      >
                        Per-trade fee (Passport)
                      </button>
                      <div class="px-3 py-2 rounded-xl border border-white/5 text-[10px] font-bold uppercase tracking-widest text-gray-600 bg-white/[0.02] cursor-not-allowed text-center">
                        Monthly · post-hackathon
                      </div>
                    </div>

                    <%!-- Chain selector (Testnet/Mainnet) --%>
                    <div class="space-y-2">
                      <p class="text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                        Settlement chain
                      </p>
                      <form phx-submit="select_chain" class="space-y-2">
                        <input type="hidden" name="agent_id" value={agent.id} />
                        <div class="grid grid-cols-2 gap-2">
                          <button
                            type="submit"
                            name="chain_id"
                            value={ChainId.testnet()}
                            class={[
                              "px-3 py-2 rounded-xl border text-[10px] font-bold uppercase tracking-widest",
                              agent.chain_id == ChainId.testnet() &&
                                "border-emerald-400 bg-emerald-500/10 text-emerald-200",
                              agent.chain_id != ChainId.testnet() &&
                                "border-white/10 text-gray-400 hover:text-white hover:border-white/20"
                            ]}
                          >
                            Testnet · {ChainId.testnet()}
                          </button>
                          <% mainnet_ready? = ChainId.mainnet_available?() %>
                          <%= if mainnet_ready? do %>
                            <button
                              type="submit"
                              name="chain_id"
                              value={ChainId.mainnet()}
                              class={[
                                "px-3 py-2 rounded-xl border text-[10px] font-bold uppercase tracking-widest",
                                agent.chain_id == ChainId.mainnet() &&
                                  "border-red-400 bg-red-500/15 text-red-100",
                                agent.chain_id != ChainId.mainnet() &&
                                  "border-red-500/30 text-red-300 hover:text-red-100 hover:border-red-400"
                              ]}
                            >
                              Mainnet · {ChainId.mainnet()}
                            </button>
                          <% else %>
                            <div class="px-3 py-2 rounded-xl border border-white/5 text-[10px] font-bold uppercase tracking-widest text-gray-600 bg-white/[0.02] cursor-not-allowed text-center" title="Operator must set AGENT_PRIVATE_KEY_MAINNET to enable Mainnet">
                              Mainnet · disabled
                            </div>
                          <% end %>
                        </div>

                        <%!-- Confirmation checkbox required when target is Mainnet
                             (CyberSec ask 5, msg 9212 — server-enforced; UI just
                             surfaces the requirement). --%>
                        <%= if mainnet_ready? and agent.chain_id != ChainId.mainnet() do %>
                          <label class="flex items-start gap-3 rounded-xl border border-red-500/40 bg-red-500/10 px-4 py-3 cursor-pointer">
                            <input type="checkbox" name="mainnet_confirm" value="true" class="mt-0.5" />
                            <span class="text-[11px] text-red-100 leading-relaxed">
                              <strong class="font-bold">I understand switching to Mainnet</strong> will route trades using my live brokerage credentials and settle fees on Kite Mainnet.
                            </span>
                          </label>
                        <% end %>
                      </form>
                      <p class="text-[10px] text-gray-500">
                        Testnet uses your paper / sandbox broker keys; Mainnet uses your live broker keys. Per-trade Passport fees settle on the chosen chain.
                      </p>
                    </div>

                    <%!-- Connect Passport panel --%>
                    <%= if Map.get(@passport_links, agent.id) do %>
                      <div class="rounded-xl border border-emerald-500/30 bg-emerald-500/[0.04] p-4 space-y-2">
                        <div class="flex items-center justify-between">
                          <div>
                            <span class="block text-[10px] font-bold text-emerald-300 uppercase tracking-widest">
                              Passport linked
                            </span>
                            <span class="font-mono text-[11px] text-gray-300 break-all">
                              {Map.get(@passport_links, agent.id).passport_wallet_address}
                            </span>
                            <span class="block text-[10px] text-gray-500 mt-1">
                              Linked {Calendar.strftime(
                                Map.get(@passport_links, agent.id).linked_at,
                                "%Y-%m-%d %H:%M UTC"
                              )}
                            </span>
                          </div>
                          <button
                            phx-click="unlink_passport"
                            phx-value-agent_id={agent.id}
                            class="px-3 py-1.5 rounded-xl border border-red-500/30 text-[10px] font-bold uppercase tracking-widest text-red-400 hover:bg-red-500/10"
                          >
                            Unlink
                          </button>
                        </div>
                      </div>
                    <% else %>
                      <div class="rounded-xl border border-white/10 bg-white/[0.02] p-4 space-y-3">
                        <div>
                          <span class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest">
                            Don't have a Passport yet?
                          </span>
                          <p class="text-[11px] text-gray-400 mt-1">
                            Install kpass locally; KAH never sees your key.
                          </p>
                          <code class="block font-mono text-[11px] text-emerald-200 bg-black/40 rounded-xl px-3 py-2 mt-2 break-all">curl -fsSL https://agentpassport.ai/install.sh | bash</code>
                        </div>

                        <form phx-submit="link_passport" class="space-y-2">
                          <input type="hidden" name="agent_id" value={agent.id} />
                          <div>
                            <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                              Passport user id
                            </label>
                            <input
                              type="text"
                              name="passport_user_id"
                              autocomplete="off"
                              class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-[12px] font-mono text-white focus:outline-none focus:border-white/30"
                            />
                            <p
                              :if={err = get_in(@passport_form_errors, [:passport_user_id, Access.at(0)])}
                              class="text-[11px] text-red-400 mt-1"
                            >
                              {err}
                            </p>
                          </div>
                          <div>
                            <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                              Passport agent id
                            </label>
                            <input
                              type="text"
                              name="passport_agent_id"
                              autocomplete="off"
                              class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-[12px] font-mono text-white focus:outline-none focus:border-white/30"
                            />
                            <p
                              :if={err = get_in(@passport_form_errors, [:passport_agent_id, Access.at(0)])}
                              class="text-[11px] text-red-400 mt-1"
                            >
                              {err}
                            </p>
                          </div>
                          <div>
                            <label class="block text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-1">
                              Wallet address (0x…)
                            </label>
                            <input
                              type="text"
                              name="passport_wallet_address"
                              autocomplete="off"
                              placeholder="0x..."
                              class="w-full bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-[12px] font-mono text-white placeholder-gray-600 focus:outline-none focus:border-white/30"
                            />
                            <p
                              :if={err = get_in(@passport_form_errors, [:passport_wallet_address, Access.at(0)])}
                              class="text-[11px] text-red-400 mt-1"
                            >
                              {err}
                            </p>
                          </div>
                          <p :if={@vault_address} class="text-[10px] text-gray-500">
                            Per-trade fee payee:
                            <span class="font-mono text-gray-400">{@vault_address}</span>
                          </p>
                          <button
                            type="submit"
                            class="w-full px-4 py-2 rounded-xl bg-white text-black text-[10px] font-black uppercase tracking-widest hover:bg-gray-100"
                          >
                            Link Passport
                          </button>
                        </form>
                      </div>
                    <% end %>
                  </div>
                </div>

                <div
                  :if={@confirm_archive_id == agent.id}
                  class="mt-4 p-4 rounded-xl border border-red-500/30 bg-red-500/5 space-y-2"
                >
                  <p class="text-xs text-red-300">
                    Archive <strong>{agent.name}</strong>? This stops the runner and auto-cancels every open trade on the broker book. Status flips to <strong>archived</strong>. The agent's history and attestations are preserved.
                  </p>
                  <div class="flex items-center gap-2">
                    <button
                      phx-click="archive"
                      phx-value-id={agent.id}
                      class="px-4 py-1.5 rounded-xl bg-red-500 text-white text-[10px] font-bold uppercase tracking-widest hover:bg-red-600"
                    >
                      Yes, archive
                    </button>
                    <button
                      phx-click="cancel_archive"
                      class="px-4 py-1.5 rounded-xl border border-white/10 text-[10px] font-bold uppercase tracking-widest text-gray-400 hover:text-white hover:border-white/20"
                    >
                      Cancel
                    </button>
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
