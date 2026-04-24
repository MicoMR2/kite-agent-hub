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
    # P4 will swap this push_navigate for a transition to :agent.
    push_navigate(socket, to: ~p"/dashboard")
  end

  defp advance(socket), do: socket

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
        <% end %>

        <div class="mt-[18px] pt-[14px] border-t border-white/[0.06] flex items-center justify-between text-[11px]">
          <%= if @step == :auth do %>
            <.link navigate={~p"/users/log-in"} class="text-[#22c55e] font-semibold hover:underline">
              Already have an account? Sign in
            </.link>
          <% else %>
            <span class="text-gray-600">Step <%= step_number(@step) %> of 5</span>
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
        <%= for n <- 1..5 do %>
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
end
