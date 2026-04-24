defmodule KiteAgentHubWeb.OnboardLive do
  @moduledoc """
  First-run onboarding flow. Entry point is the sign-up form (step: :auth).
  Later phases extend this module with the platform picker, connect-keys,
  agent-creation, and Claude-Code-handoff steps tracked in
  `docs/onboarding_handoff/IMPLEMENTATION_PLAN.md`.

  Design fidelity reference: `docs/onboarding_handoff/README.md` (Screen 1).

  Existing, fully-onboarded users MUST never land on this page — guardrail
  #1 from CyberSec pre-build review. We enforce that in mount/3 by checking
  `current_scope` and push-navigating straight to /dashboard if a user is
  already signed in. The route is ALSO wired through
  `:redirect_if_user_is_authenticated` at the plug layer so the guard fires
  before the LiveView even mounts when the request comes in over HTTP.
  """

  use KiteAgentHubWeb, :live_view

  alias KiteAgentHub.Accounts
  alias KiteAgentHub.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if authenticated?(socket) do
      {:ok, push_navigate(socket, to: ~p"/dashboard")}
    else
      {:ok,
       socket
       |> assign(:step, :auth)
       |> assign(:changeset, Accounts.change_user_registration(%User{}))
       |> assign(:page_title, "Welcome to Kite Agent Hub")}
    end
  end

  defp authenticated?(%{assigns: %{current_scope: %{user: %User{}}}}), do: true
  defp authenticated?(_), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <div class="relative min-h-screen flex items-center justify-center px-4 py-10 overflow-hidden bg-[#0a0a0f]">
      <.quorum_background />

      <div class="relative z-10 w-full max-w-[440px] kah-panel px-7 pt-7 pb-6">
        <.panel_header />

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

        <div class="mt-[18px] pt-[14px] border-t border-white/[0.06] flex items-center justify-between text-[11px]">
          <.link navigate={~p"/users/log-in"} class="text-[#22c55e] font-semibold hover:underline">
            Already have an account? Sign in
          </.link>
          <span class="font-mono text-gray-600">v2.8 · testnet</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Components ──────────────────────────────────────────────────────────────

  defp panel_header(assigns) do
    ~H"""
    <div class="flex items-center gap-[10px]">
      <.kah_logo class="h-7 w-7 drop-shadow-[0_0_16px_rgba(34,197,94,0.45)]" />
      <span class="text-[12px] font-black text-white tracking-[-0.01em]">Kite Agent Hub</span>
    </div>
    <p class="kah-eyebrow mt-[10px]">Chain ID 2368</p>
    """
  end

  # Three pulsing agent nodes feeding a coordinator. Low-motion by default;
  # CSS @media (prefers-reduced-motion) in app.css pauses animations for
  # users who opted out. The background is purely decorative — aria-hidden
  # so screen readers skip it.
  defp quorum_background(assigns) do
    ~H"""
    <div class="absolute inset-0 pointer-events-none" aria-hidden="true">
      <svg
        class="absolute inset-0 w-full h-full"
        viewBox="0 0 800 600"
        preserveAspectRatio="xMidYMid slice"
      >
        <defs>
          <radialGradient id="nodeGlow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stop-color="#22c55e" stop-opacity="0.35" />
            <stop offset="70%" stop-color="#22c55e" stop-opacity="0.08" />
            <stop offset="100%" stop-color="#22c55e" stop-opacity="0" />
          </radialGradient>
        </defs>

        <g opacity="0.55">
          <line x1="200" y1="160" x2="400" y2="300" stroke="rgba(34,197,94,0.18)" stroke-width="1" stroke-dasharray="4 10" class="mq-dash" style="animation: mq-dash 3.2s linear infinite;" />
          <line x1="620" y1="180" x2="400" y2="300" stroke="rgba(34,197,94,0.18)" stroke-width="1" stroke-dasharray="4 10" class="mq-dash" style="animation: mq-dash 4.1s linear infinite;" />
          <line x1="320" y1="470" x2="400" y2="300" stroke="rgba(34,197,94,0.18)" stroke-width="1" stroke-dasharray="4 10" class="mq-dash" style="animation: mq-dash 3.6s linear infinite;" />
        </g>

        <circle cx="200" cy="160" r="90" fill="url(#nodeGlow)" />
        <circle cx="620" cy="180" r="90" fill="url(#nodeGlow)" />
        <circle cx="320" cy="470" r="90" fill="url(#nodeGlow)" />
        <circle cx="400" cy="300" r="120" fill="url(#nodeGlow)" />

        <g stroke="rgba(34,197,94,0.5)" stroke-width="1" fill="none">
          <circle cx="200" cy="160" r="5" fill="#22c55e" />
          <circle cx="620" cy="180" r="5" fill="#22c55e" />
          <circle cx="320" cy="470" r="5" fill="#22c55e" />
          <circle cx="400" cy="300" r="7" fill="#22c55e" />
        </g>
      </svg>
    </div>
    """
  end

end
