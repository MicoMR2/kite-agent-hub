defmodule KiteAgentHubWeb.OnboardLive do
  @moduledoc """
  First-run onboarding flow. Multi-step LiveView:

    :auth       → email + password sign up (public, pre-auth)
    :platforms  → pick which venues the agent will access (authed)
    :keys       → (P3b) connect per-platform credentials
    :agent      → (P4)  name + create the agent
    :handoff    → (P4)  copy-the-API-token final screen

  Design fidelity reference: `docs/onboarding_handoff/README.md`.

  Guardrail #1 (CyberSec pre-build): users who have already completed
  onboarding (they own an agent) MUST never re-enter this flow. Mount
  checks Trading.list_agents/1 on the current org and push-navigates to
  /dashboard if one exists. Unfinished users land on the step that
  matches their state — authenticated + no agent → :platforms,
  unauthenticated → :auth.
  """

  use KiteAgentHubWeb, :live_view

  require Logger

  alias KiteAgentHub.Accounts
  alias KiteAgentHub.Accounts.User
  alias KiteAgentHub.{Credentials, Orgs, Trading}
  alias KiteAgentHubWeb.Components.QuorumBackground

  @platforms [
    %{
      id: :alpaca,
      label: "Alpaca",
      blurb: "US stocks + crypto, paper keys work.",
      env_choices: [{"Paper", "paper"}, {"Live", "live"}],
      key_id_label: "API Key ID",
      secret_label: "API Secret"
    },
    %{
      id: :kalshi,
      label: "Kalshi",
      blurb: "Prediction markets. Demo keys supported.",
      env_choices: [{"Paper (demo)", "paper"}],
      key_id_label: "Email",
      secret_label: "Password"
    },
    %{
      id: :polymarket,
      label: "Polymarket",
      blurb: "On-chain prediction markets.",
      env_choices: [{"Paper", "paper"}],
      key_id_label: "Relayer Address (0x...)",
      secret_label: "API Key"
    },
    %{
      id: :oanda,
      label: "OANDA",
      blurb: "Forex. Practice and live envs.",
      env_choices: [{"Practice", "paper"}, {"Live", "live"}],
      key_id_label: "Account ID",
      secret_label: "API Token"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    cond do
      not authenticated?(socket) ->
        {:ok,
         socket
         |> assign(:step, :auth)
         |> assign(:changeset, Accounts.change_user_registration(%User{}))
         |> assign_common()
         |> assign(:page_title, "Welcome to Kite Agent Hub")}

      onboarded?(socket) ->
        {:ok, push_navigate(socket, to: ~p"/dashboard")}

      true ->
        {:ok,
         socket
         |> assign(:step, :platforms)
         |> assign_common()
         |> assign(:page_title, "Choose your venues")}
    end
  end

  defp assign_common(socket) do
    socket
    |> assign(:platforms, @platforms)
    |> assign(:selected, MapSet.new())
    |> assign(:saved, MapSet.new())
    |> assign(:new_agent, nil)
    |> assign(:reveal_token, false)
    |> assign(:reveal_option_a, false)
    |> assign(:reveal_option_b, false)
  end

  @impl true
  def handle_event("toggle_platform", %{"id" => id}, socket) do
    atom = safe_platform_atom(id)

    if atom do
      selected =
        if MapSet.member?(socket.assigns.selected, atom),
          do: MapSet.delete(socket.assigns.selected, atom),
          else: MapSet.put(socket.assigns.selected, atom)

      {:noreply, assign(socket, :selected, selected)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("skip_platforms", _params, socket) do
    {:noreply, assign(socket, :selected, MapSet.new()) |> advance()}
  end

  def handle_event("continue_platforms", _params, socket) do
    {:noreply, advance(socket)}
  end

  def handle_event(
        "save_key",
        %{"platform" => platform_str, "credential" => attrs},
        socket
      ) do
    with atom when not is_nil(atom) <- safe_platform_atom(platform_str),
         org_id when not is_nil(org_id) <- current_org_id(socket),
         {:ok, _cred} <- save_credential(org_id, atom, attrs) do
      saved = MapSet.put(socket.assigns.saved, atom)

      {:noreply,
       socket
       |> assign(:saved, saved)
       |> put_flash(:info, "#{platform_label(atom)} connected.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("OnboardLive save_key validation: #{inspect(changeset.errors)}")
        {:noreply, put_flash(socket, :error, "Check the fields and try again.")}

      other ->
        Logger.warning("OnboardLive save_key failed: #{inspect(other)}")
        {:noreply, put_flash(socket, :error, "Could not save credential.")}
    end
  end

  def handle_event("skip_keys", _params, socket) do
    {:noreply, advance(socket)}
  end

  def handle_event("continue_keys", _params, socket) do
    {:noreply, advance(socket)}
  end

  def handle_event("create_agent", %{"agent" => attrs}, socket) do
    with org_id when not is_nil(org_id) <- current_org_id(socket),
         name <- to_string(attrs["name"] || "") |> String.trim(),
         type <- safe_agent_type(attrs["type"]),
         true <- byte_size(name) > 0 and not is_nil(type) do
      safe_attrs = %{
        "name" => name,
        "agent_type" => type,
        "organization_id" => org_id,
        "status" => "pending"
      }

      case safe_create_agent(safe_attrs) do
        {:ok, agent} ->
          {:noreply,
           socket
           |> assign(:new_agent, agent)
           |> assign(:reveal_token, false)
           |> assign(:step, :handoff)}

        {:error, %Ecto.Changeset{} = changeset} ->
          Logger.warning("OnboardLive create_agent validation: #{inspect(changeset.errors)}")
          {:noreply, put_flash(socket, :error, "Give your agent a name and try again.")}

        other ->
          Logger.warning("OnboardLive create_agent failed: #{inspect(other)}")
          {:noreply, put_flash(socket, :error, "Could not create agent. Try again.")}
      end
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Give your agent a name and pick a type.")}
    end
  end

  def handle_event("toggle_token", _params, socket) do
    {:noreply, assign(socket, :reveal_token, not Map.get(socket.assigns, :reveal_token, false))}
  end

  def handle_event("toggle_option", %{"target" => "option_a"}, socket) do
    {:noreply,
     assign(socket, :reveal_option_a, not Map.get(socket.assigns, :reveal_option_a, false))}
  end

  def handle_event("toggle_option", %{"target" => "option_b"}, socket) do
    {:noreply,
     assign(socket, :reveal_option_b, not Map.get(socket.assigns, :reveal_option_b, false))}
  end

  def handle_event("finish", _params, socket) do
    # CyberSec guardrail #3: clear the plaintext api_token from socket
    # assigns before leaving the LV. The token is hashed-safe in DB and
    # copy-to-clipboard has already fired if the user wanted it.
    {:noreply,
     socket
     |> assign(:new_agent, nil)
     |> assign(:reveal_token, false)
     |> assign(:reveal_option_a, false)
     |> assign(:reveal_option_b, false)
     |> push_navigate(to: ~p"/dashboard")}
  end

  # Catch-all so an errant phx-click from the template cannot crash the LV
  # and trigger the mount-loop (feedback_kah_lv_rescue).
  def handle_event(event, params, socket) do
    Logger.warning("OnboardLive: unhandled event #{inspect(event)} #{inspect(params)}")
    {:noreply, socket}
  end

  defp save_credential(org_id, provider, attrs) when is_map(attrs) do
    # Whitelist the attribute keys we forward — never pass arbitrary
    # client params through to upsert_credential.
    safe =
      attrs
      |> Map.take(["key_id", "secret", "env"])
      |> Map.put_new("env", "paper")

    try do
      Credentials.upsert_credential(org_id, provider, safe)
    rescue
      e ->
        Logger.error("OnboardLive credential upsert crashed: #{inspect(e)}")
        {:error, :upsert_failed}
    end
  end

  defp current_org_id(%{assigns: %{current_scope: %{user: %User{id: user_id}}}}) do
    try do
      case Orgs.list_orgs_for_user(user_id) do
        [%{id: org_id} | _] -> org_id
        _ -> nil
      end
    rescue
      _ -> nil
    end
  end

  defp current_org_id(_), do: nil

  defp platform_label(atom) do
    Enum.find_value(@platforms, fn p -> if p.id == atom, do: p.label, else: nil end) ||
      Atom.to_string(atom)
  end

  # Step machine. P4 will replace the :keys → /dashboard jump with a
  # transition into :agent (agent creation), then :handoff.
  defp advance(%{assigns: %{step: :platforms, selected: selected}} = socket) do
    if MapSet.size(selected) == 0 do
      # Skipped venue selection entirely — no keys to enter, jump out.
      push_navigate(socket, to: ~p"/dashboard")
    else
      assign(socket, :step, :keys)
    end
  end

  defp advance(%{assigns: %{step: :keys}} = socket) do
    assign(socket, :step, :agent)
  end

  defp advance(socket), do: socket

  defp safe_agent_type("research"), do: "research"
  defp safe_agent_type("conversational"), do: "conversational"
  defp safe_agent_type(_), do: nil

  defp safe_create_agent(attrs) do
    try do
      Trading.create_agent(attrs)
    rescue
      e ->
        Logger.error("OnboardLive Trading.create_agent crashed: #{inspect(e)}")
        {:error, :create_failed}
    end
  end

  # ── Guards ──────────────────────────────────────────────────────────────────

  defp authenticated?(%{assigns: %{current_scope: %{user: %User{}}}}), do: true
  defp authenticated?(_), do: false

  defp onboarded?(%{assigns: %{current_scope: %{user: %User{id: user_id}}}}) do
    try do
      case Orgs.list_orgs_for_user(user_id) do
        [%{id: org_id} | _] -> Trading.list_agents(org_id) != []
        _ -> false
      end
    rescue
      _ -> false
    end
  end

  defp onboarded?(_), do: false

  defp safe_platform_atom(id) when is_binary(id) do
    Enum.find_value(@platforms, fn %{id: a} ->
      if Atom.to_string(a) == id, do: a, else: nil
    end)
  end

  # ── Render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative min-h-screen flex items-center justify-center px-4 py-10 overflow-hidden bg-[#0a0a0f]">
      <QuorumBackground.background />

      <div class={[
        "relative z-10 w-full kah-panel px-7 pt-7 pb-6",
        if(@step == :platforms, do: "max-w-[620px]", else: "max-w-[440px]")
      ]}>
        <.panel_chrome step={@step} />

        <%= case @step do %>
          <% :auth -> %>
            <.auth_step changeset={@changeset} />
          <% :platforms -> %>
            <.platforms_step platforms={@platforms} selected={@selected} />
          <% :keys -> %>
            <.keys_step platforms={@platforms} selected={@selected} saved={@saved} />
          <% :agent -> %>
            <.agent_step />
          <% :handoff -> %>
            <.handoff_step
              agent={@new_agent}
              reveal={@reveal_token}
              reveal_option_a={@reveal_option_a}
              reveal_option_b={@reveal_option_b}
            />
        <% end %>

        <div class="mt-[18px] pt-[14px] border-t border-white/[0.06] flex items-center justify-between text-[11px]">
          <%= if @step == :auth do %>
            <.link navigate={~p"/users/log-in"} class="text-[#22c55e] font-semibold hover:underline">
              Already have an account? Sign in
            </.link>
          <% else %>
            <span class="text-gray-600">Step <%= step_number(@step) %> of 4</span>
          <% end %>
          <span class="font-mono text-gray-600">v2.8 · testnet</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────────

  attr :step, :atom, required: true

  defp panel_chrome(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-1">
      <.link
        navigate={~p"/"}
        class="text-[11px] font-semibold text-gray-400 hover:text-white transition-colors"
      >
        ← Back to home
      </.link>
      <span class="kah-eyebrow">Chain ID 2368</span>
    </div>

    <div class="flex items-center gap-[10px] mt-4">
      <.kah_logo class="h-7 w-7 drop-shadow-[0_0_16px_rgba(34,197,94,0.45)]" />
      <span class="text-[12px] font-black text-white tracking-[-0.01em]">Kite Agent Hub</span>
    </div>

    <.stepper step={@step} />
    """
  end

  attr :step, :atom, required: true

  defp stepper(assigns) do
    assigns = assign(assigns, :current, step_number(assigns.step))

    ~H"""
    <%= if @step != :auth do %>
      <div class="flex items-center gap-[6px] mt-4">
        <%= for n <- 1..4 do %>
          <div class={[
            "h-[3px] flex-1 rounded-full transition-all duration-300",
            if(n <= @current,
              do: "bg-[#22c55e] shadow-[0_0_8px_rgba(34,197,94,0.5)]",
              else: "bg-white/[0.08]")
          ]}></div>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp step_number(:auth), do: 0
  defp step_number(:platforms), do: 1
  defp step_number(:keys), do: 2
  defp step_number(:agent), do: 3
  defp step_number(:handoff), do: 4

  attr :changeset, :map, required: true

  defp auth_step(assigns) do
    ~H"""
    <h1 class="text-[28px] font-black text-white leading-[1.05] tracking-[-0.02em] mt-6">
      Bring your agents to the trading war room.
    </h1>
    <p class="mt-[10px] mb-[22px] text-[13px] text-gray-400 font-light leading-[1.6]">
      Deploy AI-powered trading agents. Every decision attested to Kite chain.
    </p>

    <.form
      :let={f}
      for={@changeset}
      action={~p"/users/register"}
      class="flex flex-col gap-[14px]"
    >
      <div>
        <label class="kah-eyebrow block mb-[6px]" for="user_email">Email</label>
        <.input
          field={f[:email]}
          id="user_email"
          type="email"
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
          class="kah-field-input"
        />
      </div>

      <div>
        <label class="kah-eyebrow block mb-[6px]" for="user_password">Password</label>
        <.input
          field={f[:password]}
          id="user_password"
          type="password"
          autocomplete="new-password"
          required
          minlength="8"
          class="kah-field-input"
        />
        <p class="mt-[6px] text-[11px] text-gray-500">8+ characters.</p>
      </div>

      <button type="submit" class="kah-btn-primary mt-[6px] w-full">
        Create account
      </button>
    </.form>
    """
  end

  attr :platforms, :list, required: true
  attr :selected, :any, required: true

  defp platforms_step(assigns) do
    ~H"""
    <p class="kah-eyebrow mt-4">Step 01 · Venues</p>
    <h1 class="text-[26px] font-black text-white leading-[1.05] tracking-[-0.02em] mt-2">
      Where will your agents trade?
    </h1>
    <p class="mt-[8px] mb-[18px] text-[13px] text-gray-400 font-light leading-[1.6]">
      Pick any combination. Research and conversational agents can read from these;
      trading agents execute through them. You can add more later.
    </p>

    <div class="grid grid-cols-1 sm:grid-cols-2 gap-[10px]">
      <%= for p <- @platforms do %>
        <% picked? = MapSet.member?(@selected, p.id) %>
        <button
          type="button"
          phx-click="toggle_platform"
          phx-value-id={p.id}
          class={[
            "kah-card text-left p-4 flex items-start gap-3",
            picked? && "ring-2 ring-[#22c55e]/50 bg-white/[0.05]"
          ]}
        >
          <div class={[
            "h-6 w-6 rounded-full flex items-center justify-center shrink-0 border transition-colors",
            if(picked?, do: "bg-[#22c55e] border-[#22c55e]", else: "border-white/20")
          ]}>
            <%= if picked? do %>
              <svg viewBox="0 0 20 20" fill="#0a0a0f" class="h-4 w-4">
                <path d="M7.5 13.5l-3-3 1.4-1.4 1.6 1.6 4.6-4.6 1.4 1.4z" />
              </svg>
            <% end %>
          </div>
          <div class="min-w-0">
            <div class="text-[13px] font-black text-white"><%= p.label %></div>
            <div class="mt-[2px] text-[11px] text-gray-400 leading-[1.4]">
              <%= p.blurb %>
            </div>
          </div>
        </button>
      <% end %>
    </div>

    <div class="flex items-center justify-between gap-3 mt-[18px]">
      <button type="button" phx-click="skip_platforms" class="kah-btn-ghost">
        Skip for now
      </button>
      <button
        type="button"
        phx-click="continue_platforms"
        class="kah-btn-primary"
        disabled={MapSet.size(@selected) == 0}
      >
        Continue
      </button>
    </div>
    """
  end

  attr :platforms, :list, required: true
  attr :selected, :any, required: true
  attr :saved, :any, required: true

  defp keys_step(assigns) do
    ~H"""
    <p class="kah-eyebrow mt-4">Step 02 · Keys</p>
    <h1 class="text-[26px] font-black text-white leading-[1.05] tracking-[-0.02em] mt-2">
      Connect your keys.
    </h1>
    <p class="mt-[8px] mb-[18px] text-[13px] text-gray-400 font-light leading-[1.6]">
      Credentials are encrypted at rest (AES-256-GCM). We only use them to route
      your agent's trades — never logged, never shared. You can skip and add later.
    </p>

    <div class="flex flex-col gap-[12px]">
      <%= for p <- @platforms, MapSet.member?(@selected, p.id) do %>
        <.key_form platform={p} saved={MapSet.member?(@saved, p.id)} />
      <% end %>
    </div>

    <div class="flex items-center justify-between gap-3 mt-[18px]">
      <button type="button" phx-click="skip_keys" class="kah-btn-ghost">
        Skip for now
      </button>
      <button type="button" phx-click="continue_keys" class="kah-btn-primary">
        Continue
      </button>
    </div>
    """
  end

  attr :platform, :map, required: true
  attr :saved, :boolean, required: true

  defp key_form(assigns) do
    ~H"""
    <div class="kah-card p-4">
      <div class="flex items-center justify-between mb-3">
        <div class="text-[13px] font-black text-white"><%= @platform.label %></div>
        <%= if @saved do %>
          <span class="text-[10px] font-bold text-[#22c55e] uppercase tracking-widest">
            ✓ Connected
          </span>
        <% end %>
      </div>

      <form phx-submit="save_key" class="flex flex-col gap-[10px]">
        <input type="hidden" name="platform" value={@platform.id} />

        <div>
          <label class="kah-eyebrow block mb-[4px]">
            <%= @platform.key_id_label %>
          </label>
          <input
            type="text"
            name="credential[key_id]"
            class="kah-field-input"
            autocomplete="off"
            spellcheck="false"
            required
          />
        </div>

        <div>
          <label class="kah-eyebrow block mb-[4px]">
            <%= @platform.secret_label %>
          </label>
          <input
            type="password"
            name="credential[secret]"
            class="kah-field-input"
            autocomplete="new-password"
            required
          />
        </div>

        <%= if length(@platform.env_choices) > 1 do %>
          <div>
            <label class="kah-eyebrow block mb-[4px]">Environment</label>
            <select name="credential[env]" class="kah-field-input">
              <%= for {label, value} <- @platform.env_choices do %>
                <option value={value}><%= label %></option>
              <% end %>
            </select>
          </div>
        <% else %>
          <input
            type="hidden"
            name="credential[env]"
            value={@platform.env_choices |> List.first() |> elem(1)}
          />
        <% end %>

        <button type="submit" class="kah-btn-ghost mt-[4px]">
          <%= if @saved, do: "Update", else: "Save" %>
        </button>
      </form>
    </div>
    """
  end

  defp agent_step(assigns) do
    ~H"""
    <p class="kah-eyebrow mt-4">Step 03 · Agent</p>
    <h1 class="text-[26px] font-black text-white leading-[1.05] tracking-[-0.02em] mt-2">
      Create your first agent.
    </h1>
    <p class="mt-[8px] mb-[18px] text-[13px] text-gray-400 font-light leading-[1.6]">
      Pick a type and give it a name. You can change the name later and
      spin up more agents from the dashboard.
    </p>

    <form phx-submit="create_agent" class="flex flex-col gap-[12px]">
      <div>
        <label class="kah-eyebrow block mb-[4px]" for="agent_name">Name</label>
        <input
          type="text"
          id="agent_name"
          name="agent[name]"
          class="kah-field-input"
          placeholder="e.g. Aurora"
          required
          maxlength="120"
          phx-mounted={JS.focus()}
        />
      </div>

      <div class="flex flex-col gap-[8px]">
        <span class="kah-eyebrow">Type</span>

        <label class="kah-card p-3 flex items-start gap-3 cursor-pointer">
          <input type="radio" name="agent[type]" value="research" checked class="mt-[3px]" />
          <div>
            <div class="text-[13px] font-black text-white">Research</div>
            <div class="mt-[2px] text-[11px] text-gray-400">
              Reads markets, posts signals, never executes on its own.
            </div>
          </div>
        </label>

        <label class="kah-card p-3 flex items-start gap-3 cursor-pointer">
          <input type="radio" name="agent[type]" value="conversational" class="mt-[3px]" />
          <div>
            <div class="text-[13px] font-black text-white">Conversational</div>
            <div class="mt-[2px] text-[11px] text-gray-400">
              Chats with you through Claude Code about the portfolio.
            </div>
          </div>
        </label>

        <label class="kah-card p-3 flex items-start gap-3 opacity-60 cursor-not-allowed">
          <input type="radio" name="agent[type]" value="trading" disabled class="mt-[3px]" />
          <div class="flex-1">
            <div class="flex items-center gap-2">
              <span class="text-[13px] font-black text-white">Trading</span>
              <span class="text-[9px] font-bold text-[#c084fc] uppercase tracking-widest border border-[#c084fc]/40 rounded-full px-2 py-[1px]">
                Soon
              </span>
            </div>
            <div class="mt-[2px] text-[11px] text-gray-400">
              Executes live orders. Needs a wallet — coming in a future release.
            </div>
          </div>
        </label>
      </div>

      <button type="submit" class="kah-btn-primary mt-[4px] w-full">
        Create agent
      </button>
    </form>
    """
  end

  attr :agent, :map, required: true
  attr :reveal, :boolean, required: true
  attr :reveal_option_a, :boolean, required: true
  attr :reveal_option_b, :boolean, required: true

  defp handoff_step(assigns) do
    ~H"""
    <p class="kah-eyebrow mt-4">Step 04 · Handoff</p>
    <h1 class="text-[26px] font-black text-white leading-[1.05] tracking-[-0.02em] mt-2">
      Meet <%= @agent && @agent.name %>.
    </h1>
    <p class="mt-[8px] mb-[18px] text-[13px] text-gray-400 font-light leading-[1.6]">
      Pick a runner — Claude Code or Codex. Both blocks pre-fill your token,
      and you can copy without revealing.
    </p>

    <div class="kah-card p-4">
      <div class="flex items-center justify-between mb-2">
        <span class="kah-eyebrow">Agent Token</span>
        <div class="flex items-center gap-3">
          <button
            type="button"
            id={"copy-token-#{@agent && @agent.id}"}
            phx-hook="CopyToClipboard"
            data-text={@agent && @agent.api_token}
            class="text-[10px] font-bold text-[#22c55e] hover:text-[#22c55e]/80 uppercase tracking-widest"
          >
            Copy
          </button>
          <button
            type="button"
            phx-click="toggle_token"
            class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
          >
            <%= if @reveal, do: "Hide", else: "Reveal" %>
          </button>
        </div>
      </div>

      <code class="block bg-black/40 border border-white/10 rounded-xl px-3 py-2 text-[11px] text-[#22c55e] font-mono truncate">
        <%= if @reveal do %>
          <%= @agent && @agent.api_token %>
        <% else %>
          <%= mask_token(@agent && @agent.api_token) %>
        <% end %>
      </code>
    </div>

    <%!-- Option A — Claude Code / Terminal --%>
    <div class="kah-card p-4 mt-3">
      <div class="flex items-center justify-between mb-2">
        <span class="text-[10px] font-black text-blue-400 uppercase tracking-widest">
          Option A — Claude Code / Terminal
        </span>
        <div class="flex items-center gap-3">
          <button
            type="button"
            id={"copy-claude-#{@agent && @agent.id}"}
            phx-hook="CopyToClipboard"
            data-text={claude_code_prompt(@agent)}
            class="text-[10px] font-bold text-blue-400 hover:text-blue-300 uppercase tracking-widest"
          >
            Copy
          </button>
          <button
            type="button"
            phx-click="toggle_option"
            phx-value-target="option_a"
            class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
          >
            <%= if @reveal_option_a, do: "Hide", else: "Reveal" %>
          </button>
        </div>
      </div>

      <%= if @reveal_option_a do %>
        <pre class="bg-black/40 border border-blue-500/20 rounded-xl p-3 text-[10px] text-gray-300 font-mono whitespace-pre-wrap leading-relaxed max-h-44 overflow-y-auto"><%= claude_code_prompt(@agent) %></pre>
        <p class="text-[10px] text-gray-600 mt-1">Paste into Claude Code or any LLM chat.</p>
      <% else %>
        <p class="text-[10px] text-gray-600">System prompt with your token embedded. Copy or reveal.</p>
      <% end %>
    </div>

    <%!-- Option B — Run with Codex Terminal --%>
    <div class="kah-card p-4 mt-3">
      <div class="flex items-center justify-between mb-2">
        <span class="text-[10px] font-black text-emerald-400 uppercase tracking-widest">
          Option B — Run with Codex Terminal
          <span class="ml-2 text-[9px] font-bold text-gray-500"><%= KiteAgentHubWeb.CodexPrompts.agent_type_label(@agent) %></span>
        </span>
        <button
          type="button"
          phx-click="toggle_option"
          phx-value-target="option_b"
          class="text-[10px] font-bold text-gray-400 hover:text-white uppercase tracking-widest"
        >
          <%= if @reveal_option_b, do: "Hide", else: "Reveal" %>
        </button>
      </div>

      <div>
        <div class="flex items-center justify-between mb-1">
          <span class="text-[9px] font-bold text-gray-500 uppercase tracking-widest">1 · Export your token</span>
          <button
            type="button"
            id={"copy-codex-export-#{@agent && @agent.id}"}
            phx-hook="CopyToClipboard"
            data-text={KiteAgentHubWeb.CodexPrompts.export_command(@agent)}
            class="text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest"
          >
            Copy
          </button>
        </div>
        <pre class="bg-black/40 border border-emerald-500/20 rounded-xl p-2 text-[10px] text-gray-300 font-mono whitespace-pre-wrap break-all"><%= if @reveal_option_b do %><%= KiteAgentHubWeb.CodexPrompts.export_command(@agent) %><% else %>export KAH_API_TOKEN="••••••••"<% end %></pre>
      </div>

      <div class="mt-2">
        <div class="flex items-center justify-between mb-1">
          <span class="text-[9px] font-bold text-gray-500 uppercase tracking-widest">2 · Launch the agent</span>
          <button
            type="button"
            id={"copy-codex-cmd-#{@agent && @agent.id}"}
            phx-hook="CopyToClipboard"
            data-text={KiteAgentHubWeb.CodexPrompts.codex_command(@agent)}
            class="text-[10px] font-bold text-emerald-400 hover:text-emerald-300 uppercase tracking-widest"
          >
            Copy
          </button>
        </div>
        <%= if @reveal_option_b do %>
          <pre class="bg-black/40 border border-emerald-500/20 rounded-xl p-3 text-[10px] text-gray-300 font-mono whitespace-pre-wrap leading-relaxed max-h-44 overflow-y-auto">codex '<%= KiteAgentHubWeb.CodexPrompts.prompt_for(@agent) %>'</pre>
        <% else %>
          <p class="text-[10px] text-gray-600 px-1">Self-contained prompt for this agent — no repo clone required. Reveal to inspect before running.</p>
        <% end %>
      </div>

      <p class="text-[10px] text-gray-500 mt-2 leading-snug">
        <span class="text-yellow-400">Requires Codex Terminal / Codex CLI.</span>
        Normal ChatGPT browser, desktop chat, or mobile chat cannot keep the agent online — they cannot run the long-poll loop locally.
      </p>
      <p class="text-[10px] text-gray-600 mt-1 leading-snug">
        If <code class="text-gray-400">codex</code> is not recognized in your terminal, install or open Codex Terminal and follow its OS-specific setup.
        <%= if KiteAgentHubWeb.CodexPrompts.can_trade?(@agent) do %>
          <span class="text-yellow-400">Trade Agent — only Trade Agents can submit trades.</span>
        <% else %>
          <span class="text-gray-500">Read-only — cannot submit trades.</span>
        <% end %>
      </p>
    </div>

    <p class="mt-[10px] text-[10px] text-gray-600 leading-[1.5]">
      Keep your token private — never paste it into a public chat, screenshot, or repo.
    </p>

    <button type="button" phx-click="finish" class="kah-btn-primary mt-[14px] w-full">
      Go to dashboard
    </button>
    """
  end

  defp mask_token(nil), do: "—"

  defp mask_token(token) when is_binary(token) do
    case byte_size(token) do
      n when n > 8 -> binary_part(token, 0, 8) <> "••••••••"
      _ -> String.duplicate("•", 12)
    end
  end

  # ── Handoff prompt blocks ───────────────────────────────────────────────────
  #
  # Both helpers run server-side against the freshly-created agent
  # (assigns.new_agent), which only the authenticated owner sees in this
  # LV. The api_token is interpolated into the rendered block but the
  # block is masked + collapsible exactly like the dashboard handoff
  # cards. No new client-side persistence — only the existing session
  # cookie + server-side socket assigns hold the token.

  @token_placeholder "kite_your_token_here"

  defp claude_code_prompt(nil), do: ""

  defp claude_code_prompt(agent) do
    name = if agent.name, do: agent.name, else: "Agent"

    token =
      case agent do
        %{api_token: t} when is_binary(t) and byte_size(t) > 0 -> t
        _ -> @token_placeholder
      end

    """
    You are #{name}, an agent connected to Kite Agent Hub (KAH).
    API base: https://kite-agent-hub.fly.dev/api/v1
    Auth header: Authorization: Bearer #{token}
    (This token is SECRET — never post it in chat or share it.)

    Open the dashboard for the full agent prompt, endpoint reference,
    and trade payload schema. Backend role enforcement decides whether
    your agent can submit trades — the prompt cannot override it.
    """
  end

end
