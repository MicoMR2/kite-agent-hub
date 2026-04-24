# Implementation Plan — Kite Agent Hub Onboarding

Ordered task list for building the onboarding flow in the existing `kite-agent-hub` Phoenix LiveView codebase. Execute top-down; each phase is a natural commit boundary.

**Target stack:** Phoenix 1.8 · LiveView 1.1 · Ecto · Tailwind v4 · daisyUI · Heroicons · Swoosh (mail) · Oban (async) · Cloak (secrets)

**Read first:**
- `README.md` in this handoff — full design spec
- `_design/screens.jsx` — reference for exact copy, layouts, and component structure
- `_design/motion.jsx` — the Quorum SVG background composition
- Your own `assets/css/app.css`, `lib/kite_agent_hub_web/components/core_components.ex`, and `lib/kite_agent_hub_web/components/layouts.ex` — DO NOT fork these patterns, extend them

---

## Phase 0 — Repo prep (15 min)

- [ ] Confirm migrations for `users`, `agents`, `platform_keys` exist. If not, add them (schemas below).
- [ ] Confirm `Cloak.Ecto` is in deps — if not, add:
  ```elixir
  {:cloak_ecto, "~> 1.3"}
  ```
  Generate a vault key, put in `config/runtime.exs`, and create `KiteAgentHub.Vault` module.
- [ ] Add ueberauth + google strategy if Google OAuth isn't wired:
  ```elixir
  {:ueberauth, "~> 0.10"},
  {:ueberauth_google, "~> 0.12"}
  ```
- [ ] Add design tokens to `assets/css/app.css`:
  - Copy the CSS custom properties from `_design/tokens.css` (colors, type, spacing, radii, shadows)
  - Add the two keyframes: `@keyframes mq-orbit { to { transform: rotate(360deg); } }` and `@keyframes mq-dash { to { stroke-dashoffset: -14; } }`
  - Add utility classes `.kah-panel`, `.kah-card`, `.kah-field-input`, `.kah-btn-primary`, `.kah-btn-ghost`, `.kah-eyebrow` — these stay aligned with the spec's color/radius/shadow values

---

## Phase 1 — Schemas & contexts (45 min)

### Schemas

- [ ] `KiteAgentHub.Accounts.User`
  ```elixir
  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :google_uid, :string
    field :email_verified_at, :utc_datetime
    field :chain_id, :integer, default: 2368
    has_many :agents, KiteAgentHub.Agents.Agent
    has_many :platform_keys, KiteAgentHub.Vault.PlatformKey
    timestamps()
  end
  ```

- [ ] `KiteAgentHub.Agents.Agent`
  ```elixir
  schema "agents" do
    field :name, :string
    field :type, Ecto.Enum, values: [:research, :conversational, :trading]
    field :bio, :string
    field :color, :string
    field :status, Ecto.Enum, values: [:pending, :active, :paused], default: :pending
    field :api_key_hash, :string         # bcrypt/argon2 of plaintext
    field :api_key_prefix, :string       # first 12 chars for display / revoke UX
    belongs_to :user, KiteAgentHub.Accounts.User
    timestamps()
  end
  ```

- [ ] `KiteAgentHub.Vault.PlatformKey` — uses `Cloak.Ecto.Binary` for encrypted fields
  ```elixir
  schema "platform_keys" do
    field :platform, Ecto.Enum, values: [:alpaca, :kalshi, :polymarket, :oanda]
    field :key_id, KiteAgentHub.Encrypted.Binary
    field :secret, KiteAgentHub.Encrypted.Binary
    field :last_tested_at, :utc_datetime
    field :last_test_status, Ecto.Enum, values: [:ok, :fail, :never], default: :never
    field :last_latency_ms, :integer
    belongs_to :user, KiteAgentHub.Accounts.User
    timestamps()
  end
  ```

### Contexts

- [ ] `KiteAgentHub.Accounts`:
  - `register_user/1`, `authenticate/2`, `get_user_by_google_uid/1`, `link_google_uid/2`
  - `send_verification_email_async/1` — enqueue Oban job; don't block onboarding

- [ ] `KiteAgentHub.Agents`:
  - `create_agent/2` → returns `{:ok, %{agent: agent, plaintext_key: "kah_..."}}`. Generates key, hashes, stores `api_key_hash` + `api_key_prefix`, returns plaintext once.
  - `list_for_user/1`
  - `rotate_key/1`
  - `generate_api_key(type)` → `"kah_#{type}_#{16bytes_b32}_#{8bytes_b32}"` (type abbreviations: `res`, `con`, `trd`)

- [ ] `KiteAgentHub.Vault`:
  - `put_key/3` (user, platform, %{key_id, secret})
  - `test_key/2` → async; returns `{:ok, latency_ms}` or `{:error, reason}`. Dispatches to per-platform probe module.
  - `KiteAgentHub.Vault.Probes.Alpaca`, `Kalshi`, `Polymarket`, `OANDA` — each `probe(key_id, secret) :: {:ok, latency_ms} | {:error, term}`. Real HTTP calls via Req. Probe hits the lightest authenticated endpoint each platform offers (e.g. `GET /v2/account` for Alpaca).

---

## Phase 2 — Routing & layout (20 min)

- [ ] Add to `router.ex`:
  ```elixir
  scope "/", KiteAgentHubWeb do
    pipe_through :browser
    live "/onboard", OnboardLive, :index
  end

  scope "/auth", KiteAgentHubWeb do
    pipe_through :browser
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end
  ```
- [ ] On successful signup/OAuth, redirect to `/onboard` with a freshly-minted session.
- [ ] `OnboardLive` uses a custom `onboard_layout/1` — not `Layouts.app/1` — because the onboarding hides the sidebar and navbar. Put it in `Layouts` as a second function component. It renders only `@inner_content` on a full-bleed `<main class="stage">` wrapped by the `QuorumBackground` component.

---

## Phase 3 — The Quorum motion background (45 min)

- [ ] Create `lib/kite_agent_hub_web/components/quorum_background.ex` — a stateless function component that renders the inline SVG described in `_design/motion.jsx`.
- [ ] Keep the SVG structure as close to the reference as possible — the animations are all declarative `<animate>` / `<animateMotion>` / `<animateTransform>`. No JS needed.
- [ ] Intensity prop: `:minimal` (default, opacity 0.35) or `:cinematic` (opacity 0.95). Production uses `:minimal`.
- [ ] Accessibility: wrap the background in `<div aria-hidden="true">` and respect `prefers-reduced-motion` — pause all `<animate>` elements via a CSS class:
  ```css
  @media (prefers-reduced-motion: reduce) {
    .kah-motion animate, .kah-motion animateMotion, .kah-motion animateTransform {
      display: none;
    }
  }
  ```
- [ ] Confirm the SVG scales correctly at 1440, 1920, and 2560 widths.

---

## Phase 4 — `OnboardLive` (2–3 hours)

- [ ] Create `lib/kite_agent_hub_web/live/onboard_live.ex` with the assigns and events listed in the README's **State Management** section.
- [ ] Render a `step_0_auth/1` through `step_4_handoff/1` function component per step. Mount returns `step: 0, mode: :signup` by default — but if the session already has `current_user`, auto-advance to `step: 1`.
- [ ] Wrap all step templates in a single `<div class="kah-panel" phx-mounted={panel_enter_js()}>` — the `panel_enter_js` helper returns a `JS.transition/3` command running the enter animation on mount. Re-key on `step` so it fires on each step change:
  ```elixir
  <.live_component
    module={__MODULE__.Step}
    id={"step-#{@step}"}
    step={@step}
    ...
  />
  ```
  (Or simpler: put `phx-mounted={panel_enter_js()}` on a div keyed with `id={"panel-#{@step}"}`.)

### 4.1 Step 0 — Sign up / Sign in
- [ ] Mode toggle in the footer (link swaps form behavior).
- [ ] Google button posts to `/auth/google`.
- [ ] Form uses `Phoenix.HTML.Form` + a simple changeset (email format, password length).
- [ ] On success: `assign(:step, 1)` and clear the credential assigns.

### 4.2 Step 1 — Platforms
- [ ] Render 4 platform cards from a module attribute `@platforms [%{id: :alpaca, ...}, ...]`.
- [ ] `phx-click="toggle_platform"` on each card. Disable Continue when list empty.
- [ ] Back button: `phx-click="step_back"` — on step 1, signs out if pressed? Or returns to step 0 without destroying session. Decide with product. Default: returns to step 0, keeps session.

### 4.3 Step 2 — Keys
- [ ] Two-column split: left = selected platform nav, right = detail card for active platform.
- [ ] Each field uses `phx-change="set_key"` to stream into `assigns.keys`.
- [ ] Test button starts a `Task.async_nolink/1` that calls `Vault.test_key/2`. LiveView handles the `:DOWN`/message with `handle_info({ref, result}, socket)` and updates `assigns.tested`.
- [ ] Counter in header: `{tested_count}/{selected_count}`.

### 4.4 Step 3 — Create agent
- [ ] 3-type grid. Trading card is locked (`class="opacity-55 pointer-events-none"`, hint chip "SOON").
- [ ] Name + bio form. `phx-submit="create_agent"`.
- [ ] On submit: call `Agents.create_agent/2`. Store `:generated_key` in assigns for one render only (don't persist in session). Advance to step 4.

### 4.5 Step 4 — Handoff
- [ ] Render the key card + terminal demo side-by-side.
- [ ] "Copy" button: `<button phx-hook="CopyKey" data-key={@generated_key}>`. Hook handles `navigator.clipboard.writeText` + UI feedback; see Phase 5.
- [ ] Terminal demo: implement as a stateless component with a CSS-driven typing animation. Simplest approach: render all 6 lines with staggered `animation-delay` values and `animation-fill-mode: backwards`; the `@keyframes` just fades + translates each line in. For the 7s loop restart, set `animation: lineIn 250ms ease-out <delay> both;` on each line and wrap the whole terminal in `animation: terminalLoop 7s infinite;` whose keyframes hide the lines at `t=99%` so they replay on `t=0%`.
- [ ] "Enter the hub →" button: `phx-click="finish"` → `push_navigate(~p"/dashboard")`.

---

## Phase 5 — JS hooks (30 min)

- [ ] Register in `assets/js/app.js`:
  ```js
  const Hooks = {};

  Hooks.CopyKey = {
    mounted() {
      this.el.addEventListener("click", async () => {
        const key = this.el.dataset.key;
        await navigator.clipboard.writeText(key);
        const original = this.el.textContent;
        this.el.textContent = "✓ Copied — now paste in terminal";
        this.el.dataset.copied = "true";
        setTimeout(() => {
          this.el.textContent = original;
          delete this.el.dataset.copied;
        }, 1800);
      });
    }
  };

  const liveSocket = new LiveSocket("/live", Socket, { hooks: Hooks, params: {_csrf_token} });
  ```

---

## Phase 6 — Tests (1–2 hours)

- [ ] `AccountsTest`: registration, authentication, Google-UID lookup
- [ ] `AgentsTest`: create_agent, key hashing (verify plaintext not stored), rotate
- [ ] `VaultTest`: encryption round-trip, each probe module with mocked Req
- [ ] `OnboardLiveTest`:
  - Render signup form
  - Submit invalid → stays on step 0 with error
  - Submit valid → advances to step 1
  - Toggle platforms, continue disabled until ≥1
  - Test-key success flow (mock probe)
  - Create agent → lands on step 4 with generated key visible
  - "Enter the hub" → redirects to `/dashboard`

---

## Phase 7 — Polish & verification (45 min)

- [ ] Run Lighthouse / axe on `/onboard` — ensure `aria-label`s on all buttons-without-text (the icon buttons, checkbox toggles)
- [ ] Verify `prefers-reduced-motion` disables the background animations
- [ ] Confirm the 5-step stepper bar highlights correctly at each step
- [ ] Responsive check at 375px (iPhone SE), 768px (iPad), 1440px (MBP). The design is desktop-first but should gracefully single-column on mobile — panels go full-bleed with 20px margin, grids collapse to single column.
- [ ] Check dark-mode only (no light-mode variant — the design is dark-native)
- [ ] Remove storyboard / variant / cinematic variants from scope — those are design-time only

---

## Phase 8 — Things that are out of scope for this handoff

These appear in the design but are follow-ons — don't implement here:
- The actual dashboard at `/dashboard` (users lands there at end of step 4)
- Kite wallet flow (needed before Trading agents unlock)
- Agent-to-agent team chat UI
- Rate-limit enforcement on agent keys (design says "600 req/hr" but real limit + enforcement is separate)
- Billing / plan gating
- Invite-a-teammate

---

## Checklist — "done" looks like

- [ ] New user can sign up with email+password → land in dashboard with 1 agent, ≤60s, 0 console errors
- [ ] New user can sign up with Google → same
- [ ] User can skip platforms entirely, skip keys entirely, still create a conversational agent, still land in dashboard
- [ ] User can test a real Alpaca paper-trading key and see the latency readout
- [ ] Generated API key is copyable via button, and matches hash stored in DB
- [ ] Attempting to access `/onboard` with a fully-onboarded user redirects to `/dashboard`
- [ ] All tests green
- [ ] Lighthouse accessibility score ≥ 95

---

## Rough effort estimate

| Phase | Effort |
|---|---|
| 0 · Repo prep | 15 min |
| 1 · Schemas & contexts | 45 min |
| 2 · Routing & layout | 20 min |
| 3 · Quorum background | 45 min |
| 4 · OnboardLive (5 steps) | 2–3 h |
| 5 · JS hooks | 30 min |
| 6 · Tests | 1–2 h |
| 7 · Polish | 45 min |
| **Total** | **~7–9 h** |

Reasonable for one focused session. The biggest risk is Phase 4 (live view orchestration) — if you can get step 0→1→4 working end-to-end first and fill in 2+3 after, you'll de-risk the flow early.
