# KAH — Custody and Key Flow
*Substantiation document for "non-custodial by design" marketing claims. Last updated: 2026-05-12. Owner: Damico Martin.*

> **Purpose.** This document explains exactly what KAH holds, what it does not, and how user credentials are protected. It is the substantiation reference for any KAH marketing claim that touches custody, keys, or non-custodial design. If a regulator, partner, or plaintiff's lawyer asks "what does KAH actually hold," this is the answer.

---

## TL;DR — the honest one-paragraph version

KAH is **non-custodial of user funds, user broker positions, and user crypto wallet keys**. KAH **is custodial of encrypted broker API credentials** that user-owned agents need in order to execute trades on user-owned broker accounts. Credentials are stored AES-256-GCM-encrypted at rest, scoped per user/org, and decrypted only in memory at the moment a trade is executed. Plaintext credentials are never logged, never written to disk, and never leave the server process they're decrypted in.

---

## What KAH does NOT custody

| Asset / data | Where it actually lives | KAH's relationship to it |
|---|---|---|
| User cash, equities, options | Alpaca brokerage account in user's name | No account relationship; no signing authority; no withdrawal ability |
| User prediction-market positions and balances | Kalshi account in user's name | No account relationship; no signing authority |
| User FX positions | OANDA account in user's name | No account relationship; no signing authority |
| User crypto private keys / wallet signing keys | User's wallet (browser extension, hardware wallet, etc.) | Never transmitted to or stored by KAH |
| Plaintext broker API secrets | Decrypted only in server memory at trade time; never written to disk, log, or session | Transient access only |

**What this means practically:**
- KAH cannot withdraw, transfer, or move user funds.
- KAH cannot trade outside the parameters the user's agent has been configured with.
- If KAH's servers went offline tomorrow, user funds at Alpaca / Kalshi / OANDA would be unaffected and accessible directly through those venues.
- If KAH's database were compromised, attackers would obtain ciphertext, not usable credentials, without also obtaining the encryption key (which is held as a Fly platform secret, not in the database).

---

## What KAH IS custodial of (the honest part)

| Item | Storage | Reason it has to exist |
|---|---|---|
| **Encrypted broker API credentials** | `api_credentials` table (org-scoped) and `vaults` table (per-user encrypted JSON blob) | User-owned trading agents run on KAH's servers and must be able to call the user's brokerage APIs. Without the credentials, the agent cannot execute the trades the user configured. |
| **User account data** | `users` table | Email, authentication, subscription state |
| **Session tokens** | Server-side session storage | Login state |
| **Trade history / audit logs** | `audit_log` table | Operational record, compliance, debugging |
| **USD-denominated wallet balance tracking** | `wallets` table | Tracks attestation-fee accounting in KAH's records — does not represent custodied user fiat |
| **KAH's own treasury vault** | KiteAI chain (`0xFC74…3465`) | KAH's own funds for fee collection. Not user funds. |

This is what "non-custodial by design" actually means in KAH's case: KAH is non-custodial of **funds and assets** but is necessarily custodial of **operational credentials needed to act on the user's account**.

---

## How credentials are protected

### Encryption at rest

All broker API credentials are encrypted using **AES-256-GCM** before being written to the database. The implementation is in `KiteAgentHub.Credentials.Cipher` (see `lib/kite_agent_hub/credentials/cipher.ex`).

**Per-record properties:**
- Each ciphertext has its own randomly-generated 12-byte IV (initialization vector)
- Each ciphertext has a 16-byte authentication tag (GCM mode authenticates the ciphertext)
- Additional authenticated data (AAD): `"kite_credential_v1"` — versioned so future re-encryption can be audited
- IV, ciphertext, and tag are stored separately in the database row

**Encryption key:**
- Read at runtime from the `CREDENTIAL_ENCRYPTION_KEY` environment variable
- 32-byte (256-bit) key, supplied as a 64-character hex string
- Stored as a **Fly.io platform secret**, not in source code, configuration files, the database, or any code repository
- Rotatable without re-encrypting all data (current key is read at runtime; if rotated, prior data requires re-encryption)
- A separate `VAULT_ENCRYPTION_KEY` exists for the per-user vault blob; same algorithm and storage

**Dev/test fallback:**
- In non-production environments, if `CREDENTIAL_ENCRYPTION_KEY` is unset, the cipher derives a 32-byte key from SHA-256 of `SECRET_KEY_BASE`. This is intentional for local development and is **never used in production** because `CREDENTIAL_ENCRYPTION_KEY` is always set as a Fly secret in the production environment.

### Access scoping

All credential reads are scoped by `org_id` (organization ID). The function signature `KiteAgentHub.Credentials.broker_slug_for(agent, broker_root)` ensures that:
- An agent can only fetch credentials belonging to its own org
- Mainnet (`chain_id=2366`) and testnet (`chain_id=2368`) credentials are kept in separate provider slugs (`alpaca` vs `alpaca_live`), so a paper-trading agent cannot accidentally load a live-trading credential

### Plaintext handling

When a credential is needed to make a broker API call:
1. Ciphertext + IV + tag is read from the database
2. The cipher decrypts in memory using the runtime key
3. The plaintext is used to construct the outbound HTTP request
4. The plaintext binary is dereferenced as soon as the request returns
5. **At no point is the plaintext written to log lines, error messages, audit log entries, telemetry, or any persisted store.** Log redaction guards are present in the credentials context (see CyberSec ask 6 in `Credentials.broker_slug_for/2`).

---

## What the marketing copy can and cannot say

Cross-referenced with `~/kite-agent-hub/legal/marketing-claims.md`:

| Marketing claim | Status | Why |
|---|---|---|
| "Non-custodial by design" | ✅ **Defensible** *(with the scope clarification below)* | Accurate when scoped to funds/assets, which is the standard meaning of "non-custodial" in fintech contexts |
| "Non-custodial of user funds" | ✅ **Strongest version** | Most accurate and least ambiguous |
| "Your keys never leave your machine" | 🔴 **Problem — drop or rephrase** | False for broker API keys, which DO leave the user's machine and live encrypted in KAH's database. True only for wallet signing keys. |
| "Your wallet keys never leave your machine" | ✅ **Defensible if true** | Verify: does KAH require any wallet signing flow that would transmit keys? If users sign locally and KAH only receives signatures, this is accurate. |
| "AES-256-GCM encryption for all stored credentials" | ✅ **Defensible** | True (see `Cipher.encrypt/1`) |
| "Your broker credentials are encrypted at rest" | ✅ **Defensible** | True |
| "We never see your plaintext credentials" | 🟡 **Partially true — needs scope** | KAH server processes do see plaintext transiently in memory during decrypt-and-call. Better phrasing: "Plaintext credentials are decrypted only in memory at trade execution and never persisted." |
| "We can't access your funds" | ✅ **Defensible** | KAH has no withdrawal authority on any broker account |

---

## Recommended public-facing language

A short, accurate, defensible block of copy for the landing page or a "Security" page:

> **What KAH does and doesn't hold**
>
> Your funds stay at your broker. KAH has no withdrawal authority over your Alpaca, Kalshi, or OANDA accounts, and no access to your crypto wallet's signing keys.
>
> To let your agents trade on your behalf, KAH stores your broker API credentials encrypted with AES-256-GCM. The encryption key lives outside the database, as a platform secret. Credentials are decrypted only in memory at the moment a trade is executed, and the plaintext is never logged or persisted.
>
> KAH is non-custodial of your funds and assets. KAH is custodial of the encrypted credentials your agents need to act. Both of those are true at the same time, and we'd rather say so than oversell.

---

## Verification status

| Item | Status | Finding |
|---|---|---|
| Are users' KiteAI wallet keys ever transmitted to KAH? | ✅ **CLOSED** (internal engineering review, 2026-05-12) | Passport signing flow is client-side only. KAH never receives user wallet keys; only signed payloads. `AGENT_PRIVATE_KEY` in `tx_signer.ex` is KAH's own platform attestation key (Fly secret) — not a user key. |
| Is `CREDENTIAL_ENCRYPTION_KEY` actually a Fly secret? | ✅ **CLOSED** (internal engineering review, 2026-05-12) | `cipher.ex:34` reads `System.get_env("CREDENTIAL_ENCRYPTION_KEY")` at runtime; not in `fly.toml`; `git grep CREDENTIAL_ENCRYPTION_KEY` returns only the code reference. Same pattern for `VAULT_ENCRYPTION_KEY` in `vaults.ex:93`. |
| Does `wallets.balance_usd` represent custodied user fiat? | ✅ **CLOSED** (internal security review, 2026-05-12) | Today it is a **ledger of platform-side credits only**. Stripe webhook records subscription credits; Stripe holds the funds, not KAH. Gasless deposit path is one-way KAH platform wallet → user vault (not user → KAH). **No path currently moves user fiat into KAH custody.** ⚠️ **Caveat:** Re-audit this row before any Stripe billing flow that escrows user funds in a KAH-controlled account (vs. Stripe's). The non-custodial story changes the moment that flips. |
| Key rotation runbook | ⚠️ **DEFERRED — post-hackathon** | No runbook exists. Rotating `CREDENTIAL_ENCRYPTION_KEY` today would brick all existing ciphertexts. AAD is versioned (`kite_credential_v1`) so a future v2 migration is possible, but the runbook isn't written. Not a launch blocker; tracked for post-hackathon. |
| DB backup protection / access controls | ⚠️ **DEFERRED — post-hackathon** | Ciphertext-at-rest property holds (attacker without the encryption key gets opaque ciphertext), but the backup storage and access ACLs on Fly Postgres haven't been audited or documented. Not a launch blocker; track for post-hackathon. |

**Summary:** 3 of 5 items closed and verified. 2 deferred post-hackathon — neither is a launch blocker, but both should be on the post-hackathon punch list. This document is **ship-ready** for substantiation purposes.
