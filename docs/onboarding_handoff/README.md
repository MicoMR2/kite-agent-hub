# Handoff: Kite Agent Hub — First-Run Onboarding

## Overview

This package specifies a **5-step first-run onboarding flow** for Kite Agent Hub:

1. **Sign up / Sign in** — email + password or Google OAuth
2. **Platform picker** — Alpaca, Kalshi, Polymarket, OANDA (optional, skippable later)
3. **Connect keys** — per-platform credential entry + test-connection (skippable)
4. **Create agent** — Research or Conversational (Trading gated behind wallet)
5. **Claude Code handoff** — copy-key card + animated terminal demo

The goal: get a new user from zero to a working agent they can talk to in under 60 seconds. Every decision is designed around "get to a working agent fast, defer everything gated on a wallet."

A full-bleed animated SVG background ("Quorum" — three agent nodes pulsing signals into a coordinator) runs behind every step to reinforce the product's multi-agent, on-chain character without pulling focus.

---

## About the Design Files

The files in `_design/` are **design references created in HTML/JSX** — an interactive prototype showing intended look and behavior. They are **not production code to copy directly**.

Your task is to **recreate these designs in the existing Phoenix LiveView codebase** (`kite-agent-hub`) using its established patterns:

- Phoenix 1.8 + LiveView 1.1
- Tailwind v4 + daisyUI (configured in `assets/css/app.css`)
- Heroicons for iconography
- `CoreComponents` module for buttons/inputs/cards
- `Layouts.app/1` as the authenticated shell

Translate the JSX components into `.heex` templates and LiveView modules. Keep the state machine in a single `OnboardLive` module with assigns for `step`, `platforms`, `keys`, `agent`. Motion backgrounds go into a stateless component rendering inline SVG + CSS keyframes.

## Fidelity

**High-fidelity.** Every color, font size, spacing value, border radius, and shadow in the design is intentional and pulled from the existing `tokens.css` / Tailwind theme in the repo. Copy text is final. The only things that are deliberately mock are:

- Platform logos (simplified inline SVGs — replace with official brand assets)
- Generated agent API keys (`kah_xxx_yyy_zzz` — replace with whatever format your token service produces)
- Test-connection latency readout ("84ms") — hook up to real venue API ping

---

## Screens / Views

### Screen 1 — Sign in / Sign up

**Purpose:** Lowest-friction entry. Collect email + password or OAuth identity. No email verification gate in the happy path; send a verification email in the background but let the user continue.

**Layout:** Centered 440px-wide frosted panel on animated quorum background. On a `min-h-screen flex items-center justify-center` container.

**Panel chrome:**
- Background `rgba(15,15,22,0.85)`, border `1px solid rgba(255,255,255,0.10)`, `border-radius: 20px`, `backdrop-filter: blur(22px)`, padding `28px 28px 24px`
- Box-shadow `0 20px 60px rgba(0,0,0,0.5)`

**Top block:**
- 28px quorum logo + "Kite Agent Hub" wordmark (900 weight, 12px, letter-spacing -0.01em)
- Chain ID eyebrow: "CHAIN ID 2368" (10px, 700, letter-spacing 0.2em, color `#6b7280`)
- 22px margin below

**Headline (toggles by mode):**
- Sign up: **"Bring your agents to the trading war room."**
- Sign in: **"Welcome back."**
- `font-size: 28px; font-weight: 900; letter-spacing: -0.02em; line-height: 1.05; color: #fff;`

**Subhead:**
- Sign up: "Deploy AI-powered trading agents. Every decision attested to Kite chain."
- Sign in: "Pick up where your agents left off."
- `font-size: 13px; color: #9ca3af; font-weight: 300; line-height: 1.6; margin: 10px 0 22px`

**Auth block (flex column, gap 14):**
1. "Continue with Google" — ghost button, full-width, with Google g-logo glyph (14px)
2. OR divider — `grid-template-columns: 1fr auto 1fr`, hairline `rgba(255,255,255,0.06)`, "OR" (9px, 700, letter-spacing 0.2em)
3. Email field (Field wrapper: eyebrow label + input)
4. Password field, hint: "8+ characters."
5. Primary CTA: "Create account" (signup) or "Sign in" (signin) — `#22c55e` solid background, `#0a0a0f` text, box-shadow `0 0 24px rgba(34,197,94,0.35)`

**Footer (separated by hairline, 18px margin-top):**
- Left: "Already have an account? **Sign in**" (toggle link, `#22c55e`, 600)
- Right: "v2.8 · testnet" in mono, `#4b5563`

**Behavior:**
- Google button: start OAuth flow via `ueberauth` or similar
- Submit validates email format + password length client-side, then POSTs to session creation
- On success, push-navigate to step 2 with a fresh LiveView mount

---

### Screen 2 — Platform picker

**Purpose:** Let the user choose which venues their agents will access. Optional — the user can skip and add later.

**Layout:** 620px panel, 2-column grid of platform cards (10px gap).

**Header:**
- Stepper bar (5 segments, 3px tall, 6px gap, current segment `#22c55e` + glow)
- Eyebrow: "STEP 01 · VENUES"
- H2: "Where will your agents trade?" (26px, 900, -0.02em)
- Sub: "Pick any combination. Research and conversational agents can read from these; trading agents execute through them. You can add more later."

**Platform list** (4 cards):

| ID | Name | Kind | Color | Description |
|---|---|---|---|---|
| alpaca | Alpaca | Equities | `#FFD400` | US stocks + options |
| kalshi | Kalshi | Prediction markets | `#00D26A` | Event contracts, CFTC-regulated |
| polymarket | Polymarket | Prediction markets | `#2D9CDB` | On-chain event markets |
| oanda | OANDA | Forex | `#FB923C` | FX majors + minors |

**Each card (selectable):**
- 20px padding, `border-radius: 16px`
- Unselected: `border 1px solid rgba(255,255,255,0.10)`, `background rgba(255,255,255,0.02)`
- Selected: `border-color rgba(34,197,94,0.35)`, `background rgba(34,197,94,0.05)`
- `backdrop-filter: blur(14px)`
- 40×40 logo tile (real platform brand mark), `border-radius: 10px`, border `1px solid <platform-color>44`, selected state adds glow `0 0 18px <color>44`
- Name (13px, 800) + kind eyebrow (9px)
- Description (12px, `#9ca3af`)
- Right-aligned 16×16 checkbox: unselected `1.5px solid rgba(255,255,255,0.15)`, selected filled `#22c55e` with `#0a0a0f` checkmark
- Hover: `filter: brightness(1.08)` on hovered card

**Footer:**
- "Back" ghost button (left)
- "Skip for now" ghost + "Continue · N selected" solid (right, disabled when N=0)

**Logos:** Use real Alpaca, Kalshi, Polymarket, OANDA brand marks (request SVGs from each provider or use their press-kit). Don't ship the placeholder SVGs in `_design/`.

---

### Screen 3 — Connect keys

**Purpose:** Collect API credentials for each selected venue. Fully skippable — trading/research agents work without venue keys.

**Layout:** 720px panel, `grid-template-columns: 240px 1fr` with 14px gap.

**Header:** stepper (step 2), eyebrow "STEP 02 · KEYS", H2 "Connect your venues.", right-aligned mono counter "N/M connected".

**Sub-copy:** "Keys are encrypted in your vault. Research and conversational agents don't need them — you can skip and add later."

**Left column (list):** selected platforms as clickable rows, 10×12 padding, 10px radius. Active: `background rgba(255,255,255,0.05)` + border `rgba(255,255,255,0.15)`. Each row: 26×26 logo + name (12px, 700) + checkmark badge if tested successfully.

**Right column (detail Card):**
- Header: 34px logo + name (14px, 800) + kind eyebrow + "paper / live" mono hint
- Fields:
  - "API Key ID" (mono input, placeholder `ALPACA-XXXXXXXXX`)
  - "Secret" (mono password input)
- "Test connection" emerald button (`rgba(34,197,94,0.10)` bg, `#22c55e` text, `rgba(34,197,94,0.25)` border)
- During test: button disabled + text "Testing…" + 3-dot bouncing indicator
- On success: button becomes "✓ Connected", mono success line "latency 84ms · account ready" in `#22c55e`

**Empty state** (no platforms selected): centered card with "No venues selected" eyebrow.

**Test-connection behavior:** POST to platform-specific probe endpoint, return `{latency_ms, account_status}` or error. Simulate 1.4s delay in the mock.

**Footer:** "Back" | "Skip for now" + ("Continue" or "Skip · add later").

---

### Screen 4 — Create agent

**Purpose:** User picks agent type, names it, writes a bio/persona. Output: a running agent record in the DB.

**Layout:** 720px panel.

**Agent types** (3-column grid, 16px padding each):

| ID | Name | Color | One-liner | Description | Available |
|---|---|---|---|---|---|
| research | Research agent | `#60a5fa` | "Signals only. Reads market data." | "Watches tickers, news, and macros. Publishes signals into your team chat. No wallet, no trades." | ✅ |
| conversational | Conversational agent | `#c084fc` | "Coordinator. Team-chat native." | "Routes between agents, summarizes decisions, talks to you in Claude Code. No wallet." | ✅ |
| trading | Trading agent | `#22c55e` | "Executes live trades via ERC-4337 vault." | "Requires a funded Kite wallet. Every decision attested on-chain." | ❌ Locked — "Needs a Kite wallet · coming next" |

- Each type card: 32×32 color-tinted icon tile (color-at-13% bg, color-at-27% border), name (13px, 800), one-liner (11px, `#9ca3af`)
- Locked card: `opacity 0.55`, `cursor: not-allowed`, dashed hairline separator + mono footer "Needs a Kite wallet · coming next" in `#6b7280`
- Locked card gets a small "SOON" amber eyebrow next to the name

**Agent icon glyphs** (14×14, color-matched):
- Research: magnifier (circle + diagonal handle)
- Conversational: chat bubble
- Trading: lightning bolt

**Form (2-column grid below type picker):**
- "Agent name" — placeholder changes by type: `Research-Scout-01` or `Coordinator-01`. Hint: "Convention: Role-Variant-Index · e.g. Research-Scout-01"
- "Display color (auto)" — read-only display showing selected type's color dot + hex in mono

**Bio field** (full-width, below form):
- Label: "Bio · persona & instructions"
- Hint: "Personality, what markets to watch, how cautious to be, how to talk. Plain English."
- 5-row textarea, placeholder changes by type:
  - Research: "Watch SPY, QQQ, and the Kalshi fed-rate markets. Flag divergences on the 15m chart. Terse updates, no fluff."
  - Conversational: "Route messages between agents. Summarize research signals into a morning brief. Dry, literal voice."

**Footer:** "Back" ghost | "Create agent" solid (disabled until name + bio + available type all present).

**Persistence:** POST to `/api/agents` creating `%Agent{}` with `type`, `name`, `bio`, `color`, `user_id`, `status: :pending`. After successful create, transition to step 5.

---

### Screen 5 — Claude Code handoff

**Purpose:** Give the user their agent's API key and teach them the 2-step flow to start chatting via Claude Code.

**Layout:** 760px panel, `grid-template-columns: 1fr 1fr` with 14px gap between key card and terminal demo.

**Success eyebrow row:** 32px emerald circle with checkmark + "AGENT CREATED · ATTESTED ON-CHAIN" eyebrow in `#22c55e`.

**H2:** "Say hi to <span style='color: <agent-color>'>Research-Scout-01</span>."

**Sub:** "Two steps to start chatting. Copy the key below, then paste it into your Claude Code terminal when prompted. The key is scoped to this one agent — revoke or rotate any time."

**Left card — "Option A · Recommended":**
- Absolute-positioned badge pill top-left: "OPTION A · RECOMMENDED" in `#0a0a0f` text on `#22c55e` pill with emerald glow
- Eyebrow: "1 · COPY AGENT API KEY"
- Mono key block: `rgba(0,0,0,0.35)` bg, `rgba(34,197,94,0.25)` border, 10px radius, 11px mono, break-all
  - **Currently displays placeholder `—Agent information—`** per latest edit. Production: render the real generated key (`kah_<type>_<rand>_<rand>` format or whatever your token service produces)
- Primary button (full-width): "Copy key" → after click: "✓ Copied — now paste in terminal" (reverts after 1.8s)
- Secondary ghost: "Rotate"
- Metadata block below separator:
  - Scope · <agent-name>
  - Network · Chain 2368 · testnet
  - Rate · 600 req/hr

**Right column — "2 · Paste into Claude Code":**
- Eyebrow: "2 · PASTE INTO CLAUDE CODE"
- Faux terminal Card, 0 padding, overflow hidden
- Terminal chrome: 3 gray traffic-light dots + mono breadcrumb `claude-code · ~/agents`
- Terminal body (220px min-height, 11.5px mono, 1.65 line-height), types out these lines on a ~7s loop:
  1. `$ claude code --kah-agent` (user gray)
  2. `? Paste your Kite Agent Hub key ›` (prompt amber)
  3. `kah_res_abc123…` (user gray, truncated)
  4. `✓ Authenticated · scope: Research-Scout-01` (emerald)
  5. `✓ Streaming agent channel · ready` (emerald)
  6. `Research-Scout-01 › hey! bio loaded. what do you want me to watch?` (agent color)
- Blinking caret between lines
- Helper line below terminal: "Paste the agent's Option A into your Claude Code terminal to begin. Once pasted, you can then open the messages icon to the bottom right of the screen and chat with your agent."

**Amber nudge card** (full width, below grid):
- `rgba(234,179,8,0.06)` bg, `rgba(234,179,8,0.20)` border, 14px radius
- Left: amber arrow chip (22×22)
- Headline (amber, 12px, 800): "Ready to trade? Add a trading agent."
- Body (12px, `#d1d5db`): "Fund a Kite wallet, connect venue keys, then deploy an ERC-4337 vault. We'll walk you through."

**Footer:** "View docs" ghost | "Enter the hub →" solid — final nav to dashboard.

---

## Motion: Quorum background

The animated background is a single inline `<svg viewBox="0 0 100 100" preserveAspectRatio="xMidYMid slice">` element, sized to fill the onboarding viewport absolutely. Zero dependencies — pure SVG + CSS `@keyframes`.

**Composition:**
- Radial emerald halo at center (`#22c55e` at 35% opacity fading out), animated `r` from 36 → 48 → 36 over 6s
- 5 concentric grid rings at radii 10/18/26/34/42 with dashed strokes, each slowly rotating at different speeds (60–120s)
- 4 orbital belts carrying colored satellites (emerald/blue/purple) at radii 14/22/30/38, alternating rotation direction
- **9 perimeter nodes** at predetermined positions, each a colored circle (emerald, blue, purple, white) with drop-shadow glow. Each node:
  - Pulses `r` from 0.8 → 1.4 → 0.8 on a 2.4s loop
  - Fires a ray toward center using `<linearGradient>` stroke
  - Emits a traveling data packet (`<animateMotion>` along the ray path) on a 3s loop
- **6 cross-links** between perimeter node pairs with dashed strokes animating `stroke-dashoffset`
- **3 concentric pulse rings** at center expanding and fading (`r` animate from 3→9 with opacity 0.4→0)
- Scanning sweep: a 42°-wide emerald cone rotating at 9s/rev with 4% opacity

**Intensity:** scales opacity from 35% (minimal variant) to 95% (cinematic). Use minimal in production — cinematic was a design exploration.

**Keyframes required** (define in `app.css`):
```css
@keyframes mq-orbit { to { transform: rotate(360deg); } }
@keyframes mq-dash  { to { stroke-dashoffset: -14; } }
```

---

## Interactions & Behavior

### Global

- Panel enter animation: `translateY(10px) → 0`, opacity `0 → 1`, 450ms, cubic-bezier(.2, .7, .2, 1). Re-fire on every step change (key the screen component on `step`).
- Buttons: `transition: all 200ms`; hover: `filter: brightness(1.08)`
- All form inputs: `rgba(255,255,255,0.02)` bg, `rgba(255,255,255,0.08)` border, 10px radius, 11/14 padding, 13px text. Focus: no ring — let the outline stay minimal (outline: none).
- Text inputs that carry technical values (API keys, addresses) use `font-family: var(--font-mono)` — everything else is Inter.

### Step 0 → 1

- Submit credentials via LiveView form event. Validate server-side; on success patch `step=1` and `push_event` the panel-enter animation.
- Google OAuth: delegate to ueberauth, return to `/onboard?step=1`.

### Step 1 toggle + continue

- Platform cards: `phx-click="toggle_platform" phx-value-id={id}`. Append/remove from `assigns.platforms`.
- Continue: `phx-click="step_next"`, no-op if platforms is empty (button disabled + `pointer-events: none`).

### Step 2 test-connection

- "Test connection" fires `phx-click="test_key" phx-value-platform={id}`. LV spawns an async Task.
- Handle `{:DOWN, ...}` or `:test_result` message in `handle_info/2`. Set `assigns.tested[id] = :ok | :fail`. Re-render auto.
- Encrypt keys before persisting: use `Cloak.Ecto` or similar, store only ciphertext.

### Step 3 create

- Submit `phx-submit="create_agent"`. Build `%Agent{}` changeset. On success: insert, transition to step 4, return the generated API key in assigns (do not persist the plaintext — store a hash; display once).

### Step 4 copy

- `phx-hook="CopyKey"` on the primary button — `navigator.clipboard.writeText` + toggle `data-copied` attr + reset after 1.8s.
- "Enter the hub" button: `push_navigate(~p"/dashboard")`.

### Animation details

| Element | Property | Values | Duration | Easing |
|---|---|---|---|---|
| Panel enter | opacity + translateY | 0→1, 10px→0 | 450ms | cubic-bezier(.2,.7,.2,1) |
| Button hover | filter | brightness(1)→brightness(1.08) | 200ms | ease |
| Stepper segment | background | gray→emerald | 300ms | ease |
| Check on test success | opacity + scale | 0→1 | 180ms | ease |
| Copied toast | none (text swap) | 1800ms delay | — | — |
| Terminal line in | opacity + translateY(3px→0) | 0→1 | 250ms | ease-out |
| Caret | opacity | 1→0 | 900ms | steps(2) |
| Quorum orbit | rotate | 0→360° | 14–38s | linear |
| Quorum pulse rings | r + opacity | small→large→fade | 3s | linear |

---

## State Management

A single LiveView — `KiteAgentHubWeb.OnboardLive` — owns the full flow.

**Assigns:**

```elixir
socket
|> assign(:step, 0)                  # 0..4
|> assign(:mode, :signup)            # :signup | :signin
|> assign(:platforms, [])            # [:alpaca, :kalshi, ...]
|> assign(:keys, %{})                # %{alpaca: %{kid: "...", sec: "..."}}
|> assign(:tested, %{})              # %{alpaca: :ok}
|> assign(:testing, nil)             # currently-testing platform id
|> assign(:agent, %{type: :research, name: "", bio: ""})
|> assign(:generated_key, nil)       # shown once on step 4
|> assign(:variant, :minimal)        # :minimal | :cinematic (default :minimal)
```

**Events:**

| Event | Payload | Effect |
|---|---|---|
| `signup_submit` | `%{email, password}` | Create user, `assign(:step, 1)` |
| `signin_submit` | `%{email, password}` | Authenticate, redirect to dashboard |
| `oauth_google` | — | `redirect to ueberauth` |
| `toggle_mode` | `%{to: "signin" \| "signup"}` | Flip assign |
| `toggle_platform` | `%{id}` | Append/remove from platforms |
| `set_key` | `%{platform, field, value}` | Update keys map |
| `test_key` | `%{platform}` | `Task.async` probe; set `:testing` |
| `test_result` (info msg) | `{platform, :ok \| :fail, latency}` | Update `:tested`, clear `:testing` |
| `step_next` | — | Increment `:step` |
| `step_back` | — | Decrement `:step` |
| `step_jump` | `%{to}` | Jump to step (dev only, behind `@enable_step_jumper`) |
| `create_agent` | form params | Insert agent, generate key, `step=4` |
| `copy_key` | — | Fires the JS hook (no server state change) |
| `finish` | — | `push_navigate(~p"/dashboard")` |

**Guards:**
- `step_next` from 1 is a no-op if `platforms == []`
- `step_next` from 2 allowed even if 0 keys tested (skippable)
- `create_agent` requires `name != ""`, `bio != ""`, `type in [:research, :conversational]`

---

## Design Tokens

### Colors

| Token | Hex | Usage |
|---|---|---|
| `--surface-0` | `#0a0a0f` | page bg |
| `--surface-1` | `rgba(15,15,22,0.85)` | panel bg |
| `--surface-2` | `rgba(255,255,255,0.02)` | card bg |
| `--surface-raise` | `rgba(255,255,255,0.05)` | hover / active row |
| `--border-hair` | `rgba(255,255,255,0.06)` | hairlines |
| `--border-default` | `rgba(255,255,255,0.10)` | card borders |
| `--text-primary` | `#ffffff` | headlines |
| `--text-body` | `#e5e7eb` | body |
| `--text-muted` | `#9ca3af` | sub-copy |
| `--text-dim` | `#6b7280` | eyebrows, metadata |
| `--text-faint` | `#4b5563` | footers |
| `--emerald` | `#22c55e` | brand accent / success / CTA |
| `--emerald-glow` | `rgba(34,197,94,0.35)` | button shadow |
| `--amber` | `#facc15` | nudges, warnings |
| `--red` | `#ef4444` | errors |
| `--agent-research` | `#60a5fa` | research agent color |
| `--agent-conv` | `#c084fc` | conversational agent color |
| `--agent-trading` | `#22c55e` | trading agent color |
| `--platform-alpaca` | `#FFD400` | Alpaca brand |
| `--platform-kalshi` | `#00D26A` | Kalshi brand |
| `--platform-polymarket` | `#2D9CDB` | Polymarket brand |
| `--platform-oanda` | `#FB923C` | OANDA brand |

### Type

- `--font-sans: "Inter", ui-sans-serif, system-ui, ...`
- `--font-mono: "JetBrains Mono", ui-monospace, Menlo, ...`
- Weights: 300 / 400 / 500 / 700 / 800 / 900
- Eyebrows: 10/11px, 700, letter-spacing `0.2em`, UPPERCASE
- Body: 13px, 300, line-height 1.6
- H2 (step headlines): 26/28px, 900, -0.02em tracking, 1.1 line-height
- Buttons: 11px, 700, `0.2em` tracking, UPPERCASE
- Mono blocks (keys, addresses): 11–11.5px

### Spacing

- Panel padding: 28/34px (cinematic = larger)
- Card padding: 20px
- Field gap: 14px
- Section gap (between panel regions): 22px
- Button gap (inside): 8px
- Stepper segment gap: 6px

### Radii

- Panels: 20px
- Cards: 16px
- Inputs: 10px
- Buttons: 12px
- Pills/badges: 9999px

### Shadows

- Panel (minimal): `0 20px 60px rgba(0,0,0,0.5)`
- Panel (cinematic): `0 40px 120px rgba(0,0,0,0.6), 0 0 60px rgba(34,197,94,0.08)`
- Emerald CTA: `0 0 24px rgba(34,197,94,0.35)`
- Emerald glow pill: `0 0 14px rgba(34,197,94,0.5)`

---

## Assets

**Logos to acquire (replace placeholders):**
- Alpaca — https://alpaca.markets (press kit)
- Kalshi — https://kalshi.com/brand
- Polymarket — https://polymarket.com (press inquiries)
- OANDA — https://www.oanda.com/about/press

**Google g-logo:** use the official SVG from https://developers.google.com/identity/branding-guidelines.

**Kite logo / "quorum" mark:** the design uses a custom quorum-themed logomark (three colored nodes routing into a green center). Source is in `_design/screens.jsx` → `QuorumLogo` function. Replace with whatever the marketing team ships.

**Icons:** Use Heroicons (already in the project). Only custom icons in the design are the 3 agent-type glyphs (magnifier, chat bubble, bolt), which are simple enough to hand-author as inline SVG.

---

## Files in this handoff

```
design_handoff_onboarding_flow/
├── README.md                    # This file — full spec
├── IMPLEMENTATION_PLAN.md       # Ordered tasks for Claude Code
└── _design/                     # Reference HTML prototype
    ├── index.html               # Entry point — open in a browser
    ├── motion.jsx               # Three animated SVG backgrounds
    ├── screens.jsx              # All 5 step screens + shared atoms
    ├── prototype.jsx            # Step orchestrator with state machine
    ├── storyboard.jsx           # All-in-one stacked view
    ├── tweaks-panel.jsx         # Variant switcher (can ignore)
    └── tokens.css               # Design tokens (colors, type, spacing)
```

To view the prototype locally, serve the `_design/` folder with any static HTTP server and open `index.html`. The Tweaks panel at bottom-right lets you flip between the prototype and storyboard views.

---

## Open questions for the team

1. **Email verification** — block step 2 until verified, or send in background and surface a soft banner? Current design assumes background.
2. **Platform keys storage** — are you using `Cloak.Ecto` already or do we need to add encrypted-at-rest storage?
3. **API key format** — confirm `kah_<type>_<rand>_<rand>` or propose a replacement. The key must be revocable and hash-storable.
4. **Rate limit** — "600 req/hr" in the key metadata is a design placeholder. Confirm real number.
5. **Locked trading agent** — show it or hide it? Current design shows + disables with "Needs a Kite wallet · coming next" to advertise the roadmap. Swap to hidden if this is confusing pre-release.
6. **Skippability of keys** — confirm users can fully skip step 2 and come back later. This matters for the "continue" button behavior on that step.
