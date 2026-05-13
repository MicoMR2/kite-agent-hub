# KAH Marketing Claims — Running Log
*Source of truth for every claim that appears in KAH marketing copy. Maintained by Mico. Last updated: 2026-05-12.*

> **Rules of the road:** Every factual claim that ships needs an entry here with status, substantiation reference, and the surface(s) it appears on. Before adding new copy, check the **Banned** section. Before going live with a new claim, mark it **Approved** and link its substantiation. When a claim is removed from a surface, mark the surface removed rather than deleting the row — the history is the audit trail.
>
> **Core framing rule:** Using KAH is **as risky as making trades yourself**. KAH neither reduces nor magnifies trading risk. Any copy that implies otherwise — in either direction — is wrong and gets cut.
>
> **Reference:** Marketing claim rules live in `~/.claude/plugins/config/claude-for-legal/product-legal/CLAUDE.md` → `## Marketing claims — standing guardrails`. This file is the *log of claims in active use*; that file is the *rules of what claims are allowed*.

---

## Status legend

| Status | Meaning |
|---|---|
| ✅ **Approved** | Claim is true, substantiated, and may appear in marketing |
| 🟡 **Pending sub** | Claim is in use but lacks a substantiation reference — write one or pull the claim |
| 🔴 **Banned** | Claim is not allowed in any KAH marketing surface |
| ⚫ **Retired** | Previously approved, since removed; kept for audit trail |

---

## Active claims (currently shipping)

| # | Claim (exact text) | Type | Status | Substantiation ref | Surfaces |
|---|---|---|---|---|---|
| 1 | "BYO-LLM" | Factual / feature | ✅ Approved | Product spec — any MCP-compatible LLM client may connect | landing hero badge |
| 2 | "Alpaca + Kalshi" | Factual / integration | ✅ Approved | Integration list in product config | landing hero badge |
| 3 | "Non-custodial" *(scope: of user funds and assets)* | Factual | ✅ Approved | [`custody-and-key-flow.md`](./custody-and-key-flow.md) — confirms KAH holds no fund withdrawal authority or wallet signing keys | landing hero badge, subhead |
| 4 | "On Kite Chain" / "settled on Kite chain" | Factual | ✅ Approved | KiteAI testnet/mainnet attestation rail, chain_id=2368 | landing hero badge, subhead |
| 5 | "Autonomous AI agents" | Factual | ✅ Approved | Product is AI agents that run autonomously per user configuration | landing H1 |
| 6 | "Deploy AI trading agents that execute on Alpaca and Kalshi" | Factual | ✅ Approved | Same as #1, #2 | landing subhead |
| 7 | "Bring your own LLM — Claude Code, Claude Desktop, or any MCP-compatible client" | Factual | ✅ Approved | Product supports MCP standard | landing subhead |
| 8 | "Configurable spending limits" | Factual | 🟡 Pending sub | Need to verify in-product limits (per-trade $5K cap is documented; per-day / per-agent not surfaced in marketing) | landing subhead |
| 9 | "Live P&L tracking" *(use this; avoid "real-time")* | Factual | ✅ Approved | Dashboard polls Alpaca / Kalshi position data on configured interval | landing subhead |
| 10 | "Your keys never leave your machine" | Factual | 🔴 **Banned — drop or rephrase** | [`custody-and-key-flow.md`](./custody-and-key-flow.md) confirms broker API keys DO leave the user's machine (encrypted on KAH servers). Only wallet signing keys stay local. Replace with one of the approved variants in row 11 or 12. | landing subhead — **needs replacement** |
| 11 | "Your wallet signing keys stay on your machine" | Factual | ✅ Approved | [`custody-and-key-flow.md`](./custody-and-key-flow.md) — internal engineering review confirmed client-side signing for Passport / KiteAI; KAH receives only signed payloads | *(suggested replacement; not yet in production copy)* |
| 12 | "Broker credentials encrypted with AES-256-GCM at rest" | Factual | ✅ Approved | [`custody-and-key-flow.md`](./custody-and-key-flow.md) — `Credentials.Cipher` uses AES-256-GCM with per-record IV + auth tag; key held as Fly secret | *(suggested replacement; not yet in production copy)* |

---

## Banned (do not use)

| Banned text or pattern | Reason | Approved alternative |
|---|---|---|
| "Trade while you sleep" | Implies hands-off / no monitoring → contradicts user-responsibility framing | "Your strategy, running 24/7" |
| "Set it and forget it" | Same family — implies risk-free / no attention required | "Set your strategy, let your agent run it" |
| "Hands-off trading" | Same family | "Automate the execution. You own the strategy." |
| "Passive income" / "Earn passively" / "Make money in your sleep" | Implies guaranteed return + no effort + reduced risk | Don't use any equivalent |
| "Let KAH trade for you" / "Let our agents handle it" | Factually wrong — KAH doesn't trade; users' own agents trade on users' own accounts | "Your agents, your accounts, your strategy" |
| "Guaranteed [anything]" / "risk-free" / "no-risk" | Trading is risky; KAH guarantees nothing | Don't use any equivalent |
| "Smarter than human traders" / "Beats the market" / "Outperforms [competitor]" | Comparative performance claims — substantiation unavailable | Drop the comparison; describe the feature only |
| "Reduce / minimize / lower your trading risk" | KAH doesn't change trading risk | "Same risk as trading yourself, delivered through agents you configure" |
| "AI-powered investment advice" / "Smart investing" / advisory framing | KAH is not an investment adviser | Stay in tooling/infrastructure framing |
| "Powered by Claude AI" *(as a standalone hero claim)* | Contradicts BYO-LLM; implies exclusive Claude integration | "Built for Claude Code" or match BYO-LLM framing |
| "Real-time" *(in any P&L or data context)* | "Real-time" has a regulatory meaning in market-data contexts; latency makes it inaccurate | "Live" |
| "scored with QRB edge analysis" *(specifically the word "edge")* | "Edge" is a performance/comparative claim requiring substantiation we don't have | "scored with QRB analysis" |
| "Trusted by [N] traders" before [N] is real and current | False user-count claims | Don't use until [N] is documented and current |

---

## Pending substantiation (in use but not yet documented)

These claims are live in copy but don't have a substantiation file behind them. **Either write the substantiation or pull the claim — both options are fine; "in production without backup" is the only option that isn't.**

| Claim | What substantiation looks like | Owner | Status |
|---|---|---|---|
| "Non-custodial of user funds" | One-pager documenting key/credential flow | Mico | ✅ **Done** → [`custody-and-key-flow.md`](./custody-and-key-flow.md) |
| "Your wallet signing keys stay on your machine" *(replacement for the banned "your keys never leave your machine")* | Audit the Passport / KiteAI signing flow to confirm signing happens client-side and KAH only receives signed payloads | Engineering team | ✅ **Done** → Internal engineering review confirmed signing is client-side; KAH only receives signed payloads. See `custody-and-key-flow.md` verification table. |
| "Configurable spending limits" | Doc: what limits the product actually exposes (per-trade $5K is in memory but is it user-configurable? Per-day? Per-agent?). Marketing claim should match what users can actually set. | Mico | Pending |
| "QRB analysis" *(if kept)* | One-pager: what QRB measures, what data feeds it, how scores are produced. Doesn't have to claim an edge — just has to explain what it is. | Engineering team | Pending |

---

## Retired (removed from marketing — kept for audit)

| # | Claim | Removed | Reason |
|---|---|---|---|
| R-1 | "Trade while you sleep" | 2026-05-12 *(planned)* | Marketing claims review — implied hands-off / risk-free framing |
| R-2 | "Powered by Claude AI" *(standalone)* | 2026-05-12 *(planned)* | Contradicts BYO-LLM messaging on sibling page |
| R-3 | "Real-time P&L tracking" | 2026-05-12 *(planned)* | "Real-time" is a regulatory defined term; replaced with "Live" |
| R-4 | "scored with QRB edge analysis" | 2026-05-12 *(planned)* | "Edge" implies unsubstantiated comparative performance; replaced with "QRB analysis" |

*(Move retired claims here with the actual removal date once the new copy ships.)*

---

## Adjacent risk language (required where it appears)

The landing page should carry a short risk acknowledgment **adjacent to the primary CTAs**, not just in a footer. The exact text is approved here:

> **Trading carries substantial risk.** KAH does not reduce trading risk — your agent trades on your own broker accounts under your delegation. [Read the full risk disclosure.](/legal/risk-disclosure)

**Why this is required:** Under FTC unfair-deceptive practices analysis `[verify]`, the *net impression* of a marketing surface matters more than any single claim. A hero promising autonomous trading without a visible risk acknowledgment can be deceptive even if every individual claim is true. The adjacent disclosure is the inexpensive fix.

---

## Process — adding a new claim

1. Draft the claim.
2. Match against **Banned** section. If banned or a banned-pattern variant — stop, use an approved alternative.
3. Classify: puffery / factual / comparative / implied / absolute.
4. If factual / comparative / implied / absolute: write the substantiation reference (link to a doc, a benchmark, a product spec).
5. Add row to **Active claims** with status `🟡 Pending sub` if substantiation isn't ready yet, or `✅ Approved` if it is.
6. Ship.
7. If a regulator, plaintiff's lawyer, or partner ever asks "where does this claim come from" — point them at this file.

---

## Surfaces tracked

- `kite_agent_hub/lib/kite_agent_hub_web/live/home_live.html.heex` — primary landing (live version)
- `kite_agent_hub/lib/kite_agent_hub_web/controllers/page_html/home.html.heex` — *(scheduled for deletion per agent-team decision 2026-05-12)*
- `~/kite-agent-hub/legal/trading-agent-risk-disclosure.md` — risk disclosure (draft)
- *(Add as new surfaces appear: docs, blog, social, email, demos)*
