/* global React */
/* Shared atoms first, then the 5 step screens.
   All components export to window for cross-file use. */

const { useState, useEffect, useRef } = React;

/* ─── Atoms ─────────────────────────────────────────────────── */
function Eyebrow({ children, color, style }) {
  return (
    <span style={{
      fontSize: 10, fontWeight: 700, letterSpacing: "0.2em",
      textTransform: "uppercase", color: color || "#6b7280",
      ...style
    }}>{children}</span>);

}

function Mono({ children, style }) {
  return <span style={{ fontFamily: 'var(--font-mono)', ...style }}>{children}</span>;
}

function Btn({ variant = "primary", children, onClick, disabled, icon, style, full }) {
  const base = {
    display: "inline-flex", alignItems: "center", justifyContent: "center", gap: 8,
    padding: "12px 22px", borderRadius: 12,
    fontSize: 11, fontWeight: 700, letterSpacing: "0.2em",
    textTransform: "uppercase",
    border: "1px solid rgba(255,255,255,0.10)",
    cursor: disabled ? "not-allowed" : "pointer",
    transition: "all .2s",
    fontFamily: "inherit",
    width: full ? "100%" : "auto",
    opacity: disabled ? 0.4 : 1
  };
  const variants = {
    primary: { background: "rgba(255,255,255,0.08)", color: "#fff" },
    ghost: { background: "transparent", color: "#9ca3af", border: "1px solid rgba(255,255,255,0.08)" },
    emerald: { background: "rgba(34,197,94,0.10)", color: "#22c55e", border: "1px solid rgba(34,197,94,0.25)" },
    solid: { background: "#22c55e", color: "#0a0a0f", border: "1px solid #22c55e",
      boxShadow: "0 0 24px rgba(34,197,94,0.35)" }
  };
  return (
    <button style={{ ...base, ...variants[variant], ...style }} onClick={onClick} disabled={disabled}>
      {icon}{children}
    </button>);

}

function Field({ label, children, hint }) {
  return (
    <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
      <Eyebrow>{label}</Eyebrow>
      {children}
      {hint && <span style={{ fontSize: 11, color: "#6b7280", lineHeight: 1.5 }}>{hint}</span>}
    </label>);

}

function Input({ value, onChange, placeholder, type = "text", mono }) {
  return (
    <input
      value={value || ""}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      type={type}
      style={{
        background: "rgba(255,255,255,0.02)",
        border: "1px solid rgba(255,255,255,0.08)",
        borderRadius: 10,
        padding: "11px 14px",
        fontSize: 13,
        color: "#fff",
        outline: "none",
        fontFamily: mono ? "var(--font-mono)" : "inherit",
        width: "100%"
      }} />);


}

function Textarea({ value, onChange, placeholder, rows = 4 }) {
  return (
    <textarea
      value={value || ""}
      onChange={(e) => onChange(e.target.value)}
      placeholder={placeholder}
      rows={rows}
      style={{
        background: "rgba(255,255,255,0.02)",
        border: "1px solid rgba(255,255,255,0.08)",
        borderRadius: 10,
        padding: "11px 14px",
        fontSize: 13, lineHeight: 1.55,
        color: "#fff", outline: "none",
        fontFamily: "inherit", resize: "vertical",
        width: "100%"
      }} />);


}

function Card({ children, style, tone, selected, onClick }) {
  const base = {
    borderRadius: 16,
    border: `1px solid ${selected ? "rgba(34,197,94,0.35)" : "rgba(255,255,255,0.10)"}`,
    background: selected ? "rgba(34,197,94,0.05)" : "rgba(255,255,255,0.02)",
    backdropFilter: "blur(14px)",
    padding: 20,
    transition: "all .18s",
    cursor: onClick ? "pointer" : "default",
    ...style
  };
  if (tone === "emerald" && !selected) {
    base.borderColor = "rgba(34,197,94,0.22)";
    base.background = "linear-gradient(to right, rgba(34,197,94,0.06), rgba(34,197,94,0.02))";
  }
  return <div style={base} onClick={onClick}>{children}</div>;
}

/* ─── Panel shell used by every step in prototype mode ──────── */
function StepPanel({ children, width = 520, cinematic }) {
  return (
    <div style={{
      width, maxWidth: "92vw",
      background: cinematic ? "rgba(12,12,18,0.72)" : "rgba(15,15,22,0.85)",
      border: "1px solid rgba(255,255,255,0.10)",
      borderRadius: 20,
      padding: cinematic ? "34px 34px 30px" : "28px 28px 24px",
      backdropFilter: "blur(22px)",
      boxShadow: cinematic ?
      "0 40px 120px rgba(0,0,0,0.6), 0 0 60px rgba(34,197,94,0.08)" :
      "0 20px 60px rgba(0,0,0,0.5)",
      position: "relative",
      zIndex: 2
    }}>
      {children}
    </div>);

}

function Stepper({ steps, current }) {
  return (
    <div style={{ display: "flex", gap: 6, alignItems: "center", marginBottom: 22 }}>
      {steps.map((s, i) =>
      <div key={i} style={{
        flex: 1, height: 3, borderRadius: 9999,
        background: i < current ? "#22c55e" : i === current ? "rgba(34,197,94,0.4)" : "rgba(255,255,255,0.08)",
        boxShadow: i === current ? "0 0 8px rgba(34,197,94,0.5)" : "none",
        transition: "all .3s"
      }} />
      )}
    </div>);

}

/* ═══════════════════════════════════════════════════════════════
   SCREEN 1 — Sign in / Sign up
   ═══════════════════════════════════════════════════════════════ */
function SignInScreen({ onDone, cinematic }) {
  const [mode, setMode] = useState("signup"); // signup | signin
  const [email, setEmail] = useState("");
  const [pw, setPw] = useState("");

  const headline = mode === "signup" ?
  "Bring your agents to the trading war room." :
  "Welcome back.";
  const sub = mode === "signup" ?
  "Deploy AI-powered trading agents. Every decision attested to Kite chain." :
  "Pick up where your agents left off.";

  return (
    <StepPanel width={440} cinematic={cinematic}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 22 }}>
        <QuorumLogo size={28} />
        <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
          <span style={{ fontSize: 12, fontWeight: 900, color: "#fff", letterSpacing: "-0.01em" }}>
            Kite Agent Hub
          </span>
          <Eyebrow style={{ fontSize: 9 }}>Chain ID 2368</Eyebrow>
        </div>
      </div>

      <h1 style={{
        margin: 0, fontSize: cinematic ? 34 : 28,
        fontWeight: 900, letterSpacing: "-0.02em",
        lineHeight: 1.05, color: "#fff"
      }}>
        {headline}
      </h1>
      <p style={{ margin: "10px 0 22px", fontSize: 13, color: "#9ca3af",
        fontWeight: 300, lineHeight: 1.6 }}>
        {sub}
      </p>

      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        <Btn variant="ghost" full icon={<GoogleGlyph />}>
          Continue with Google
        </Btn>

        <div style={{
          display: "grid", gridTemplateColumns: "1fr auto 1fr",
          alignItems: "center", gap: 10, color: "#4b5563",
          fontSize: 9, fontWeight: 700, letterSpacing: "0.2em",
          textTransform: "uppercase"
        }}>
          <span style={{ height: 1, background: "rgba(255,255,255,0.06)" }} />
          <span>OR</span>
          <span style={{ height: 1, background: "rgba(255,255,255,0.06)" }} />
        </div>

        <Field label="Email">
          <Input value={email} onChange={setEmail} type="email" placeholder="you@agent.hub" />
        </Field>
        <Field label="Password" hint={mode === "signup" ?
        "8+ characters." :
        null}>
          <Input value={pw} onChange={setPw} type="password" placeholder="••••••••••••" />
        </Field>

        <Btn variant="solid" full onClick={onDone}>
          {mode === "signup" ? "Create account" : "Sign in"}
        </Btn>
      </div>

      <div style={{ marginTop: 18, paddingTop: 16,
        borderTop: "1px solid rgba(255,255,255,0.05)",
        display: "flex", justifyContent: "space-between",
        fontSize: 11, color: "#6b7280" }}>
        <span>
          {mode === "signup" ? "Already have an account? " : "New here? "}
          <a onClick={() => setMode(mode === "signup" ? "signin" : "signup")}
          style={{ color: "#22c55e", cursor: "pointer", fontWeight: 600 }}>
            {mode === "signup" ? "Sign in" : "Create account"}
          </a>
        </span>
        <Mono style={{ fontSize: 10, color: "#4b5563" }}>v2.8 · testnet</Mono>
      </div>
    </StepPanel>);

}

/* ═══════════════════════════════════════════════════════════════
   SCREEN 2 — Platform picker
   ═══════════════════════════════════════════════════════════════ */
const PLATFORMS = [
{ id: "alpaca", name: "Alpaca", kind: "Equities", color: "#facc15", desc: "US stocks + options" },
{ id: "kalshi", name: "Kalshi", kind: "Prediction markets", color: "#00d26a", desc: "Event contracts, CFTC-regulated" },
{ id: "polymarket", name: "Polymarket", kind: "Prediction markets", color: "#2a72e5", desc: "On-chain event markets" },
{ id: "oanda", name: "OANDA", kind: "Forex", color: "#fb923c", desc: "FX majors + minors" }];


/* Real brand logomarks (simplified but recognizable inline SVGs).
   Each is rendered at 22x22. Uses currentColor where appropriate. */
function PlatformLogo({ id, size = 22 }) {
  const s = size;
  if (id === "alpaca") {
    // Alpaca Markets: yellow circle with stylized alpaca silhouette
    return (
      <svg width={s} height={s} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="15" fill="#FFD400" />
        <path d="M10 22c0-4 1.5-7 4-8 .3-1.6 1.2-2.6 2.3-2.6 1 0 1.7.7 1.9 1.8.2-.1.4-.1.6-.1 1.2 0 2.2 1 2.2 2.4 0 .4-.1.8-.3 1.1 1.6.7 2.8 2.7 2.8 5.4H10z"
        fill="#111" />
        <circle cx="19.2" cy="13.6" r="0.7" fill="#FFD400" />
      </svg>);

  }
  if (id === "kalshi") {
    // Kalshi: green square with angular K monogram
    return (
      <svg width={s} height={s} viewBox="0 0 32 32" fill="none">
        <rect width="32" height="32" rx="7" fill="#00D26A" />
        <path d="M11 9v14h3v-5.2l1.8-2L21 23h3.5l-6.3-8.6L23.5 9H20l-5 5.8h-1V9h-3z" fill="#0a0a0f" />
      </svg>);

  }
  if (id === "polymarket") {
    // Polymarket: blue rounded square with stylized P
    return (
      <svg width={s} height={s} viewBox="0 0 32 32" fill="none">
        <rect width="32" height="32" rx="8" fill="#2D9CDB" />
        <path d="M11 8h6.2c3.5 0 5.8 2.2 5.8 5.4 0 3.2-2.3 5.4-5.8 5.4H14v5.2h-3V8zm3 2.6v5.6h3c1.8 0 3-1.1 3-2.8s-1.2-2.8-3-2.8h-3z"
        fill="#fff" />
      </svg>);

  }
  if (id === "oanda") {
    // OANDA: orange ring with dot
    return (
      <svg width={s} height={s} viewBox="0 0 32 32" fill="none">
        <circle cx="16" cy="16" r="15" fill="#111" />
        <circle cx="16" cy="16" r="9" stroke="#FB923C" strokeWidth="3" fill="none" />
        <circle cx="16" cy="16" r="2.2" fill="#FB923C" />
      </svg>);

  }
  return null;
}

function PlatformStep({ selected, onToggle, onNext, onBack, cinematic }) {
  return (
    <StepPanel width={620} cinematic={cinematic}>
      <Stepper steps={[0, 1, 2, 3, 4]} current={1} />
      <Eyebrow>Step 01 · Venues</Eyebrow>
      <h2 style={{ margin: "6px 0 8px", fontSize: 26, fontWeight: 900,
        letterSpacing: "-0.02em", color: "#fff", lineHeight: 1.1 }}>
        Where will your agents trade?
      </h2>
      <p style={{ margin: "0 0 22px", fontSize: 13, color: "#9ca3af",
        fontWeight: 300, lineHeight: 1.6 }}>
        Pick any combination. Research and conversational agents can read from these; trading
        agents execute through them. You can add more later.
      </p>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
        {PLATFORMS.map((p) => {
          const on = selected.includes(p.id);
          return (
            <Card key={p.id} selected={on} onClick={() => onToggle(p.id)}>
              <div style={{ display: "flex", alignItems: "flex-start", gap: 12 }}>
                <div style={{
                  width: 40, height: 40, borderRadius: 10,
                  background: "rgba(255,255,255,0.03)",
                  border: `1px solid ${p.color}44`,
                  display: "flex", alignItems: "center", justifyContent: "center",
                  flexShrink: 0,
                  boxShadow: on ? `0 0 18px ${p.color}44` : "none",
                  transition: "all .2s"
                }}><PlatformLogo id={p.id} size={24} /></div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                    <span style={{ fontSize: 13, fontWeight: 800, color: "#fff" }}>{p.name}</span>
                    <Eyebrow style={{ fontSize: 9 }}>{p.kind}</Eyebrow>
                  </div>
                  <div style={{ fontSize: 12, color: "#9ca3af", marginTop: 3, lineHeight: 1.5 }}>
                    {p.desc}
                  </div>
                </div>
                <div style={{
                  width: 16, height: 16, borderRadius: 4,
                  border: `1.5px solid ${on ? "#22c55e" : "rgba(255,255,255,0.15)"}`,
                  background: on ? "#22c55e" : "transparent",
                  display: "flex", alignItems: "center", justifyContent: "center",
                  flexShrink: 0, transition: "all .18s"
                }}>
                  {on && <CheckGlyph color="#0a0a0f" />}
                </div>
              </div>
            </Card>);

        })}
      </div>

      <div style={{ display: "flex", justifyContent: "space-between",
        alignItems: "center", marginTop: 22 }}>
        <Btn variant="ghost" onClick={onBack}>Back</Btn>
        <div style={{ display: "flex", gap: 8 }}>
          <Btn variant="ghost" onClick={onNext}>Skip for now</Btn>
          <Btn variant="solid" onClick={onNext} disabled={selected.length === 0}>
            Continue · {selected.length || 0} selected
          </Btn>
        </div>
      </div>
    </StepPanel>);

}

/* ═══════════════════════════════════════════════════════════════
   SCREEN 3 — API keys
   ═══════════════════════════════════════════════════════════════ */
function KeysStep({ selected, keys, onKey, onNext, onBack, cinematic }) {
  const active = selected.filter((id) => PLATFORMS.find((p) => p.id === id));
  const [openId, setOpenId] = useState(active[0] || null);
  const [testing, setTesting] = useState(null); // id being tested
  const [tested, setTested] = useState({}); // id -> "ok"|"fail"

  // Simulate test connection
  function runTest(id) {
    setTesting(id);
    setTimeout(() => {
      setTesting(null);
      setTested((t) => ({ ...t, [id]: "ok" }));
    }, 1400);
  }

  const completed = active.filter((id) => tested[id] === "ok").length;
  const p = PLATFORMS.find((x) => x.id === openId);

  return (
    <StepPanel width={720} cinematic={cinematic}>
      <Stepper steps={[0, 1, 2, 3, 4]} current={2} />
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
        <div>
          <Eyebrow>Step 02 · Keys</Eyebrow>
          <h2 style={{ margin: "6px 0 8px", fontSize: 26, fontWeight: 900,
            letterSpacing: "-0.02em", color: "#fff", lineHeight: 1.1 }}>
            Connect your venues.
          </h2>
        </div>
        <Mono style={{ fontSize: 11, color: "#6b7280" }}>
          {completed}/{active.length} connected
        </Mono>
      </div>
      <p style={{ margin: "0 0 20px", fontSize: 13, color: "#9ca3af",
        fontWeight: 300, lineHeight: 1.6 }}>
        Keys are encrypted in your vault. Research and conversational agents don't need them —
        you can <a onClick={onNext} style={{ color: "#22c55e", cursor: "pointer" }}>skip</a> and
        add later.
      </p>

      {active.length === 0 ?
      <Card style={{ padding: 32, textAlign: "center" }}>
          <Eyebrow>No venues selected</Eyebrow>
          <div style={{ marginTop: 10, fontSize: 14, color: "#d1d5db" }}>
            You can come back to this any time.
          </div>
        </Card> :

      <div style={{ display: "grid", gridTemplateColumns: "240px 1fr", gap: 14 }}>
          {/* list */}
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {active.map((id) => {
            const p = PLATFORMS.find((x) => x.id === id);
            const ok = tested[id] === "ok";
            return (
              <div key={id} onClick={() => setOpenId(id)} style={{
                display: "flex", alignItems: "center", gap: 10,
                padding: "10px 12px", borderRadius: 10,
                background: openId === id ? "rgba(255,255,255,0.05)" : "rgba(255,255,255,0.01)",
                border: `1px solid ${openId === id ? "rgba(255,255,255,0.15)" : "rgba(255,255,255,0.05)"}`,
                cursor: "pointer"
              }}>
                  <PlatformLogo id={p.id} size={22} />
                  <span style={{ flex: 1, fontSize: 12, fontWeight: 700, color: "#fff" }}>
                    {p.name}
                  </span>
                  {ok &&
                <span style={{
                  width: 14, height: 14, borderRadius: 9999,
                  background: "rgba(34,197,94,0.15)",
                  border: "1px solid rgba(34,197,94,0.35)",
                  display: "flex", alignItems: "center", justifyContent: "center",
                  color: "#22c55e"
                }}><CheckGlyph /></span>
                }
                </div>);

          })}
          </div>

          {/* form */}
          {p &&
        <Card style={{ padding: 22 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 16 }}>
                <PlatformLogo id={p.id} size={34} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 14, fontWeight: 800, color: "#fff" }}>{p.name}</div>
                  <Eyebrow style={{ fontSize: 9 }}>{p.kind}</Eyebrow>
                </div>
                <Mono style={{ fontSize: 10, color: "#6b7280" }}>paper / live</Mono>
              </div>
              <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
                <Field label="API Key ID">
                  <Input mono placeholder={`${p.id.toUpperCase()}-XXXXXXXXX`}
              value={keys[p.id]?.kid}
              onChange={(v) => onKey(p.id, "kid", v)} />
                </Field>
                <Field label="Secret">
                  <Input mono type="password" placeholder="•••• •••• •••• ••••"
              value={keys[p.id]?.sec}
              onChange={(v) => onKey(p.id, "sec", v)} />
                </Field>
                <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
                  <Btn variant="emerald" onClick={() => runTest(p.id)} disabled={testing === p.id}>
                    {testing === p.id ? "Testing…" : tested[p.id] === "ok" ? "✓ Connected" : "Test connection"}
                  </Btn>
                  {testing === p.id && <Dots />}
                  {tested[p.id] === "ok" &&
              <Mono style={{ fontSize: 11, color: "#22c55e" }}>
                      latency 84ms · account ready
                    </Mono>
              }
                </div>
              </div>
            </Card>
        }
        </div>
      }

      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 22 }}>
        <Btn variant="ghost" onClick={onBack}>Back</Btn>
        <div style={{ display: "flex", gap: 8 }}>
          <Btn variant="ghost" onClick={onNext}>Skip for now</Btn>
          <Btn variant="solid" onClick={onNext}>
            {completed > 0 ? "Continue" : "Skip · add later"}
          </Btn>
        </div>
      </div>
    </StepPanel>);

}

/* ═══════════════════════════════════════════════════════════════
   SCREEN 4 — Create agent
   ═══════════════════════════════════════════════════════════════ */
const AGENT_TYPES = [
{
  id: "research",
  name: "Research agent",
  color: "#60a5fa",
  oneliner: "Signals only. Reads market data.",
  desc: "Watches tickers, news, and macros. Publishes signals into your team chat. No wallet, no trades.",
  available: true
},
{
  id: "conversational",
  name: "Conversational agent",
  color: "#c084fc",
  oneliner: "Coordinator. Team-chat native.",
  desc: "Routes between agents, summarizes decisions, talks to you in Claude Code. No wallet.",
  available: true
},
{
  id: "trading",
  name: "Trading agent",
  color: "#22c55e",
  oneliner: "Executes live trades via ERC-4337 vault.",
  desc: "Requires a funded Kite wallet. Every decision attested on-chain.",
  available: false,
  locked: "Needs a Kite wallet · coming next"
}];


function AgentStep({ agent, onChange, onNext, onBack, cinematic }) {
  const chosen = AGENT_TYPES.find((t) => t.id === agent.type);

  return (
    <StepPanel width={720} cinematic={cinematic}>
      <Stepper steps={[0, 1, 2, 3, 4]} current={3} />
      <Eyebrow>Step 03 · Agent</Eyebrow>
      <h2 style={{ margin: "6px 0 8px", fontSize: 26, fontWeight: 900,
        letterSpacing: "-0.02em", color: "#fff", lineHeight: 1.1 }}>
        Bring your first agent online.
      </h2>
      <p style={{ margin: "0 0 20px", fontSize: 13, color: "#9ca3af",
        fontWeight: 300, lineHeight: 1.6 }}>
        Pick a type, give it a name and a short bio. It'll be ready to talk in a minute.
      </p>

      <Eyebrow style={{ display: "block", marginBottom: 10 }}>Type</Eyebrow>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3,1fr)", gap: 10, marginBottom: 20 }}>
        {AGENT_TYPES.map((t) => {
          const on = agent.type === t.id;
          return (
            <Card key={t.id} selected={on}
            onClick={() => t.available && onChange({ ...agent, type: t.id })}
            style={{
              opacity: t.available ? 1 : 0.55,
              cursor: t.available ? "pointer" : "not-allowed",
              padding: 16
            }}>
              <div style={{
                width: 32, height: 32, borderRadius: 9,
                background: `${t.color}22`, border: `1px solid ${t.color}44`,
                display: "flex", alignItems: "center", justifyContent: "center",
                color: t.color, fontSize: 13, fontWeight: 900,
                marginBottom: 10
              }}>
                <AgentGlyph kind={t.id} />
              </div>
              <div style={{ fontSize: 13, fontWeight: 800, color: "#fff",
                display: "flex", alignItems: "center", gap: 6,
                flexWrap: "wrap" }}>
                {t.name}
                {!t.available && <Eyebrow color="#facc15" style={{ fontSize: 8 }}>Soon</Eyebrow>}
              </div>
              <div style={{ fontSize: 11, color: "#9ca3af", marginTop: 4, lineHeight: 1.5 }}>
                {t.oneliner}
              </div>
              {!t.available &&
              <Mono style={{ display: "block", marginTop: 10, fontSize: 10,
                color: "#6b7280", paddingTop: 10,
                borderTop: "1px dashed rgba(255,255,255,0.05)" }}>
                  {t.locked}
                </Mono>
              }
            </Card>);

        })}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14 }}>
        <Field label="Agent name"
        hint="Convention: Role-Variant-Index · e.g. Research-Scout-01">
          <Input value={agent.name} onChange={(v) => onChange({ ...agent, name: v })}
          placeholder={chosen?.id === "research" ? "Research-Scout-01" : "Coordinator-01"} />
        </Field>
        <Field label="Display color (auto)">
          <div style={{
            padding: "11px 14px", borderRadius: 10,
            background: "rgba(255,255,255,0.02)",
            border: "1px solid rgba(255,255,255,0.08)",
            display: "flex", alignItems: "center", gap: 10,
            fontSize: 12, color: "#d1d5db"
          }}>
            <span style={{
              width: 10, height: 10, borderRadius: 9999,
              background: chosen?.color || "#9ca3af",
              boxShadow: `0 0 8px ${chosen?.color || "#9ca3af"}`
            }} />
            <Mono style={{ fontSize: 11 }}>{chosen?.color || "—"}</Mono>
            <span style={{ marginLeft: "auto", fontSize: 11, color: "#6b7280" }}>
              from type
            </span>
          </div>
        </Field>
      </div>

      <div style={{ marginTop: 14 }}>
        <Field label="Bio · persona & instructions"
        hint="Personality, what markets to watch, how cautious to be, how to talk. Plain English.">
          <Textarea value={agent.bio} onChange={(v) => onChange({ ...agent, bio: v })}
          rows={5}
          placeholder={chosen?.id === "research" ?
          "Watch SPY, QQQ, and the Kalshi fed-rate markets. Flag divergences on the 15m chart. Terse updates, no fluff." :
          "Route messages between agents. Summarize research signals into a morning brief. Dry, literal voice."} />
        </Field>
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 22 }}>
        <Btn variant="ghost" onClick={onBack}>Back</Btn>
        <Btn variant="solid" onClick={onNext}
        disabled={!agent.name || !agent.bio || !chosen?.available}>
          Create agent
        </Btn>
      </div>
    </StepPanel>);

}

/* ═══════════════════════════════════════════════════════════════
   SCREEN 5 — Claude Code handoff
   ═══════════════════════════════════════════════════════════════ */
function HandoffStep({ agent, onDone, cinematic }) {
  const apiKey = `kah_${agent.type?.slice(0, 3) || "agt"}_${Math.random().toString(36).slice(2, 10)}_${Math.random().toString(36).slice(2, 10)}`;
  const [copied, setCopied] = useState(false);

  function copy() {
    try {navigator.clipboard.writeText(apiKey);} catch {}
    setCopied(true);
    setTimeout(() => setCopied(false), 1800);
  }

  const color = AGENT_TYPES.find((t) => t.id === agent.type)?.color || "#22c55e";

  return (
    <StepPanel width={760} cinematic={cinematic}>
      <Stepper steps={[0, 1, 2, 3, 4]} current={4} />

      <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 4 }}>
        <div style={{
          width: 32, height: 32, borderRadius: 9999,
          background: "rgba(34,197,94,0.18)",
          border: "1px solid rgba(34,197,94,0.35)",
          display: "flex", alignItems: "center", justifyContent: "center",
          color: "#22c55e", boxShadow: "0 0 14px rgba(34,197,94,0.35)"
        }}><CheckGlyph size={14} /></div>
        <Eyebrow color="#22c55e">Agent created · attested on-chain</Eyebrow>
      </div>
      <h2 style={{ margin: "8px 0 8px", fontSize: 28, fontWeight: 900,
        letterSpacing: "-0.02em", color: "#fff", lineHeight: 1.1 }}>
        Say hi to <span style={{ color }}>{agent.name}</span>.
      </h2>
      <p style={{ margin: "0 0 18px", fontSize: 13, color: "#9ca3af",
        fontWeight: 300, lineHeight: 1.6 }}>
        Two steps to start chatting. Copy the key below, then paste it into your Claude Code
        terminal when prompted. The key is scoped to this one agent — revoke or rotate any time.
      </p>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14 }}>
        {/* Key card — Option A */}
        <Card tone="emerald" style={{ padding: 20, position: "relative" }}>
          <div style={{
            position: "absolute", top: -10, left: 16,
            display: "inline-flex", alignItems: "center", gap: 6,
            padding: "3px 10px", borderRadius: 9999,
            color: "#0a0a0f",
            fontSize: 9, fontWeight: 900, letterSpacing: "0.2em",
            textTransform: "uppercase",
            boxShadow: "0 0 14px rgba(34,197,94,0.5)", background: "rgb(34, 125, 197)"
          }}>Option A · Recommended</div>
          <Eyebrow color="#22c55e" style={{ marginTop: 4 }}>1 · Copy agent API key</Eyebrow>
          <div style={{
            marginTop: 10, padding: "12px 14px",
            background: "rgba(0,0,0,0.35)",
            border: "1px solid rgba(34,197,94,0.25)",
            borderRadius: 10,
            fontFamily: "var(--font-mono)",
            fontSize: 11, color: "#d1d5db",
            wordBreak: "break-all", lineHeight: 1.6
          }}>—Agent information—</div>

          <div style={{ display: "flex", gap: 8, marginTop: 14 }}>
            <Btn variant="solid" onClick={copy} full>
              {copied ? "✓ Copied — now paste in terminal" : "Copy key"}
            </Btn>
            <Btn variant="ghost">Rotate</Btn>
          </div>

          <div style={{
            marginTop: 16, paddingTop: 14,
            borderTop: "1px solid rgba(255,255,255,0.06)",
            display: "flex", flexDirection: "column", gap: 8
          }}>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11 }}>
              <span style={{ color: "#6b7280" }}>Scope</span>
              <Mono style={{ color: "#d1d5db" }}>{agent.name}</Mono>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11 }}>
              <span style={{ color: "#6b7280" }}>Network</span>
              <Mono style={{ color: "#d1d5db" }}>Chain 2368 · testnet</Mono>
            </div>
            <div style={{ display: "flex", justifyContent: "space-between", fontSize: 11 }}>
              <span style={{ color: "#6b7280" }}>Rate</span>
              <Mono style={{ color: "#d1d5db" }}>600 req/hr</Mono>
            </div>
          </div>
        </Card>

        {/* Terminal demo — labeled as step 2 */}
        <div style={{ display: "flex", flexDirection: "column" }}>
          <div style={{
            display: "inline-flex", alignItems: "center", gap: 8,
            marginBottom: 8
          }}>
            <Eyebrow color="#d1d5db">2 · Paste into Claude Code</Eyebrow>
          </div>
          <TerminalDemo agent={agent} apiKey={apiKey} />
          <div style={{
            marginTop: 8,
            fontSize: 11, color: "#6b7280",
            lineHeight: 1.5
          }}>
            Paste the agent's Option A into your Claude Code terminal to begin. Once pasted, you can
            then open the messages icon to the bottom right of the screen and chat with your agent.
          </div>
        </div>
      </div>

      <div style={{
        marginTop: 18, padding: "14px 18px",
        borderRadius: 14,
        background: "rgba(234,179,8,0.06)",
        border: "1px solid rgba(234,179,8,0.20)",
        display: "flex", alignItems: "flex-start", gap: 12
      }}>
        <div style={{
          width: 22, height: 22, borderRadius: 9999,
          background: "rgba(234,179,8,0.20)",
          color: "#facc15", flexShrink: 0,
          display: "flex", alignItems: "center", justifyContent: "center",
          fontWeight: 900, fontSize: 13
        }}>→</div>
        <div>
          <div style={{ fontSize: 12, fontWeight: 800, color: "#facc15", letterSpacing: "-0.01em" }}>
            Ready to trade? Add a trading agent.
          </div>
          <div style={{ fontSize: 12, color: "#d1d5db", marginTop: 3, lineHeight: 1.5 }}>
            Fund a Kite wallet, connect venue keys, then deploy an ERC-4337 vault. We'll walk you through.
          </div>
        </div>
      </div>

      <div style={{ display: "flex", justifyContent: "space-between", marginTop: 22 }}>
        <Btn variant="ghost">View docs</Btn>
        <Btn variant="solid" onClick={onDone}>Enter the hub →</Btn>
      </div>
    </StepPanel>);

}

/* Animated faux terminal */
function TerminalDemo({ agent, apiKey }) {
  const steps = [
  { t: 200, text: "$ claude code --kah-agent", kind: "user" },
  { t: 900, text: "? Paste your Kite Agent Hub key ›", kind: "prompt" },
  { t: 1800, text: apiKey.slice(0, 22) + "…", kind: "user" },
  { t: 2700, text: "✓ Authenticated · scope: " + agent.name, kind: "ok" },
  { t: 3300, text: "✓ Streaming agent channel · ready", kind: "ok" },
  { t: 4100, text: `${agent.name} › hey! bio loaded. what do you want me to watch?`, kind: "agent" }];

  const [shown, setShown] = useState(0);
  useEffect(() => {
    setShown(0);
    const timers = steps.map((s, i) => setTimeout(() => setShown((n) => Math.max(n, i + 1)), s.t));
    // loop
    const loop = setTimeout(() => setShown(0), 7200);
    return () => {timers.forEach(clearTimeout);clearTimeout(loop);};
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agent.name, shown === 0 ? 0 : 1]);

  // gentle loop restart every 8s
  useEffect(() => {
    const iv = setInterval(() => setShown(0), 8200);
    return () => clearInterval(iv);
  }, []);

  const color = AGENT_TYPES.find((t) => t.id === agent.type)?.color || "#22c55e";

  return (
    <Card style={{ padding: 0, overflow: "hidden" }}>
      <div style={{
        display: "flex", alignItems: "center", gap: 6,
        padding: "9px 12px",
        background: "rgba(255,255,255,0.02)",
        borderBottom: "1px solid rgba(255,255,255,0.05)"
      }}>
        <span style={{ width: 9, height: 9, borderRadius: 9999, background: "rgba(255,255,255,0.12)" }} />
        <span style={{ width: 9, height: 9, borderRadius: 9999, background: "rgba(255,255,255,0.12)" }} />
        <span style={{ width: 9, height: 9, borderRadius: 9999, background: "rgba(255,255,255,0.12)" }} />
        <Mono style={{ marginLeft: 10, fontSize: 10, color: "#6b7280" }}>claude-code · ~/agents</Mono>
      </div>
      <div style={{
        padding: 14, minHeight: 220,
        fontFamily: "var(--font-mono)",
        fontSize: 11.5, lineHeight: 1.65,
        color: "#d1d5db"
      }}>
        {steps.slice(0, shown).map((s, i) => {
          const col = s.kind === "ok" ? "#22c55e" :
          s.kind === "prompt" ? "#facc15" :
          s.kind === "agent" ? color :
          "#d1d5db";
          return (
            <div key={i} style={{ color: col, marginBottom: 2,
              opacity: 0, animation: "term-in .25s ease-out forwards",
              whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
              {s.text}
            </div>);

        })}
        {shown > 0 && shown < steps.length &&
        <span style={{ color, animation: "caret 0.9s steps(2) infinite" }}>▍</span>
        }
      </div>
    </Card>);

}

/* ─── Tiny glyph helpers ────────────────────────────────────── */
function QuorumLogo({ size = 24 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 180 180" fill="none">
      <circle cx="90" cy="90" r="34" fill="rgba(34,197,94,0.10)" />
      <line x1="24" y1="30" x2="90" y2="90" stroke="#60a5fa" strokeWidth="6" strokeLinecap="round" />
      <line x1="156" y1="30" x2="90" y2="90" stroke="#c084fc" strokeWidth="6" strokeLinecap="round" />
      <line x1="90" y1="168" x2="90" y2="90" stroke="#fff" strokeWidth="6" strokeLinecap="round" />
      <circle cx="24" cy="30" r="12" fill="#60a5fa" />
      <circle cx="156" cy="30" r="12" fill="#c084fc" />
      <circle cx="90" cy="168" r="12" fill="#fff" />
      <circle cx="90" cy="90" r="18" fill="#22c55e" style={{ filter: "drop-shadow(0 0 6px #22c55e)" }} />
    </svg>);

}

function CheckGlyph({ color = "#fff", size = 10 }) {
  return (
    <svg width={size} height={size} viewBox="0 0 12 12" fill="none">
      <path d="M2.5 6L5 8.5L9.5 3.5" stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
    </svg>);

}

function GoogleGlyph() {
  return (
    <svg width="14" height="14" viewBox="0 0 18 18">
      <path fill="#ea4335" d="M9 3.48a5.02 5.02 0 013.55 1.39l2.65-2.65A8.94 8.94 0 009 0a9 9 0 00-8.05 4.97l3.09 2.4A5.39 5.39 0 019 3.48z" />
      <path fill="#4285f4" d="M17.64 9.2c0-.64-.06-1.25-.17-1.84H9v3.48h4.84a4.14 4.14 0 01-1.79 2.72l2.82 2.18a8.58 8.58 0 002.77-6.54z" />
      <path fill="#fbbc05" d="M4.04 10.63a5.4 5.4 0 010-3.46l-3.09-2.4A9.02 9.02 0 000 9c0 1.44.34 2.8.95 4l3.09-2.37z" />
      <path fill="#34a853" d="M9 18c2.43 0 4.47-.8 5.96-2.18l-2.82-2.18c-.78.52-1.78.83-3.14.83a5.39 5.39 0 01-4.96-3.69L.95 13.17A9 9 0 009 18z" />
    </svg>);

}

function AgentGlyph({ kind }) {
  // minimal shape per agent kind
  if (kind === "research") {
    return <svg width="14" height="14" viewBox="0 0 18 18" fill="none">
      <circle cx="8" cy="8" r="5" stroke="currentColor" strokeWidth="1.6" />
      <line x1="12" y1="12" x2="16" y2="16" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>;
  }
  if (kind === "conversational") {
    return <svg width="14" height="14" viewBox="0 0 18 18" fill="none">
      <path d="M3 4h12v8H7l-4 3V4z" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" />
    </svg>;
  }
  return <svg width="14" height="14" viewBox="0 0 18 18" fill="none">
    <path d="M10 2L4 10h4l-1 6 7-8h-4l1-6z" fill="currentColor" />
  </svg>;
}

function Dots() {
  return (
    <span style={{ display: "inline-flex", gap: 3 }}>
      {[0, 1, 2].map((i) =>
      <span key={i} style={{
        width: 4, height: 4, borderRadius: 9999, background: "#22c55e",
        animation: `dots-bounce 1s infinite ${i * 0.15}s`
      }} />
      )}
    </span>);

}

Object.assign(window, {
  Eyebrow, Mono, Btn, Field, Input, Textarea, Card, StepPanel, Stepper,
  SignInScreen, PlatformStep, KeysStep, AgentStep, HandoffStep,
  QuorumLogo, CheckGlyph, PLATFORMS, AGENT_TYPES
});