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
  alias KiteAgentHubWeb.Components.QuorumBackground

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
      <QuorumBackground.background />

      <div class="relative z-10 w-full max-w-[440px] kah-panel px-7 pt-7 pb-6">
        <div class="flex items-center justify-between mb-1">
          <.link
            navigate={~p"/"}
            class="text-[11px] font-semibold text-gray-400 hover:text-white transition-colors"
          >
            ← Back to home
          </.link>
          <span class="kah-eyebrow">Chain ID 2368</span>
        </div>

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
    <div class="flex items-center gap-[10px] mt-4">
      <.kah_logo class="h-7 w-7 drop-shadow-[0_0_16px_rgba(34,197,94,0.45)]" />
      <span class="text-[12px] font-black text-white tracking-[-0.01em]">Kite Agent Hub</span>
    </div>
    """
  end

end
