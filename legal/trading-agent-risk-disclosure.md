RESEARCH NOTES — NOT LEGAL ADVICE — REVIEW WITH A LICENSED ATTORNEY BEFORE ACTING

---

# Kite Agent Hub — Risk Disclosure
*Draft v0.2 — 2026-05-12. For attorney review before publishing.*

---

## What Kite Agent Hub Is

Kite Agent Hub ("KAH") is a software platform that helps users set up and run trading agents on their own brokerage and trading platform accounts. The agents belong to you. KAH provides the infrastructure to make that happen.

KAH is not a broker-dealer, investment adviser, trading platform, execution venue, custodian, or money services business. KAH does not execute trades, hold funds, or provide investment advice.

---

## Your Agents, Your Trades, Your Risk

**The agents are yours.** When you use KAH to set up a trading agent, that agent is your software operating under your control on your accounts. KAH facilitates the setup — it does not own, operate, supervise, or take responsibility for your agent's behavior or trading decisions.

**The trades are yours.** Your agent trades on accounts you own at brokerages and platforms you have selected. KAH has no account relationship with those venues, no visibility into your positions, and no ability to intervene in, pause, or reverse any trade.

**The risk is yours.** Trading involves substantial risk of loss. KAH has no role in any trading outcome. Nothing about using KAH — including the setup, infrastructure, dashboard, or any feature — reduces or transfers the risk inherent in trading.

---

## What KAH Does Not Do

- Execute or route any trade on your behalf
- Provide investment advice, trading recommendations, or market analysis
- Monitor your agent's compliance with brokerage margin requirements, position limits, or trading rules
- Monitor your brokerage account balances, equity, or margin status
- Guarantee any trading outcome, system uptime, or agent behavior

---

## Regulatory Compliance Is Your Responsibility

You are responsible for ensuring your agent trades in compliance with all applicable laws and regulations. Key areas to understand:

**Margin and intraday trading rules.** As of June 4, 2026, FINRA replaced the pattern day trader (PDT) framework — including the $25,000 minimum equity requirement — with new intraday margin standards under Rule 4210. Your brokerage enforces these requirements. Your agent is responsible for operating within them. KAH does not monitor margin compliance. `[verify: FINRA RN 26-10]`

**Securities laws.** Agent-directed trading is subject to the same securities laws as human-directed trading, including prohibitions on market manipulation, insider trading, and wash trading. Your agent's conduct is your conduct.

**Brokerage terms.** Your brokerage's terms of service govern automated and agent-directed trading on your account. You are responsible for ensuring your use of KAH complies with those terms.

---

## Subscription Payments

KAH charges a subscription fee for access to the platform. Subscription payments are processed by Stripe. KAH does not handle, store, or transmit payment card data. All other financial activity — including any trading activity — occurs entirely outside KAH on your own accounts.

---

## No Investment Advice

Nothing provided through KAH constitutes investment advice, a recommendation to buy or sell any security or instrument, or a solicitation. KAH is not a registered investment adviser.

---

## Limitation of Liability `[review — attorney must confirm enforceability]`

KAH's liability is limited to subscription fees paid in the 30 days preceding the claim. KAH is not liable for trading losses, missed trades, regulatory fines, or any other damages arising from your use of the platform or your agent's trading activity.

---

## Open items pending finalization

This is a working draft. The following items are flagged for attorney review before this disclosure is treated as final and surfaced to users:

- Confirm FINRA Regulatory Notice 26-10 effective date (June 4, 2026) and phase-in window (through October 20, 2027) against the primary source at finra.org/rules-guidance/notices/26-10
- Confirm enforceability of the liability cap for a consumer SaaS in the relevant jurisdictions — consumer protection statutes in some states may limit it
- Confirm no investment adviser registration is triggered by KAH's current scope (setup tooling, no advice, no discretion)
- Once Stripe subscriptions are live, confirm no MSB / money-transmitter registration is required (Stripe acts as the payment processor; KAH should not itself be a money transmitter under the current model)
