/* global React, SignInScreen, PlatformStep, KeysStep, AgentStep, HandoffStep,
          MotionQuorum, MotionBlockstream, MotionKite, QuorumLogo */
const { useState, useMemo } = React;

/* The animated full-bleed background switches by motion style. */
function MotionLayer({ style, intensity = 1 }) {
  return (
    <div style={{
      position: "absolute", inset: 0, pointerEvents: "none",
      overflow: "hidden", zIndex: 0,
    }}>
      {style === "quorum"     && <MotionQuorum intensity={intensity}/>}
      {style === "blockstream"&& <MotionBlockstream intensity={intensity}/>}
      {style === "kite"       && <MotionKite intensity={intensity}/>}
      {/* vignette + grain */}
      <div style={{
        position: "absolute", inset: 0,
        background: "radial-gradient(ellipse at center, transparent 40%, rgba(0,0,0,0.55) 100%)",
      }}/>
    </div>
  );
}

/* A step-labeled side rail used only in cinematic variant */
function SideRail({ step }) {
  const labels = [
    { k: "01", t: "Account" },
    { k: "02", t: "Venues" },
    { k: "03", t: "Keys" },
    { k: "04", t: "Agent" },
    { k: "05", t: "Handoff" },
  ];
  return (
    <div style={{
      position: "absolute", left: 40, top: "50%",
      transform: "translateY(-50%)",
      display: "flex", flexDirection: "column", gap: 22,
      zIndex: 3,
    }}>
      {labels.map((l, i) => {
        const state = i < step ? "done" : i === step ? "on" : "off";
        return (
          <div key={l.k} style={{
            display: "flex", alignItems: "center", gap: 12,
            opacity: state === "off" ? 0.35 : 1,
            transition: "all .3s",
          }}>
            <div style={{
              width: 26, height: 26, borderRadius: 9999,
              border: `1px solid ${state === "on" ? "#22c55e" : "rgba(255,255,255,0.15)"}`,
              background: state === "done" ? "rgba(34,197,94,0.20)"
                        : state === "on" ? "rgba(34,197,94,0.08)"
                        : "transparent",
              display: "flex", alignItems: "center", justifyContent: "center",
              fontFamily: "var(--font-mono)", fontSize: 10,
              color: state === "off" ? "#6b7280" : "#22c55e",
              boxShadow: state === "on" ? "0 0 12px rgba(34,197,94,0.4)" : "none",
            }}>{state === "done" ? "✓" : l.k}</div>
            <span style={{
              fontSize: 10, fontWeight: 700, letterSpacing: "0.2em",
              textTransform: "uppercase",
              color: state === "on" ? "#fff" : "#6b7280",
            }}>{l.t}</span>
          </div>
        );
      })}
    </div>
  );
}

/* Corner chrome for cinematic variant — mimics terminal dashboards */
function CornerChrome() {
  return (
    <>
      <div style={{
        position: "absolute", top: 26, right: 32, zIndex: 3,
        display: "flex", alignItems: "center", gap: 14,
        fontSize: 10, fontWeight: 700, letterSpacing: "0.2em",
        textTransform: "uppercase", color: "#6b7280",
        fontFamily: "var(--font-mono)",
      }}>
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          <span style={{
            width: 6, height: 6, borderRadius: 9999, background: "#22c55e",
            boxShadow: "0 0 8px #22c55e", animation: "pulse 2s infinite",
          }}/>
          chain 2368
        </span>
        <span>·</span>
        <span>block 8,241,603</span>
      </div>
      <div style={{
        position: "absolute", bottom: 24, right: 32, zIndex: 3,
        fontSize: 10, fontWeight: 700, letterSpacing: "0.2em",
        textTransform: "uppercase", color: "#4b5563",
      }}>
        powered by claude
      </div>
    </>
  );
}

/* ═══════════════════════════════════════════════════════════════
   The prototype — manages state across 5 steps.
   ═══════════════════════════════════════════════════════════════ */
function Prototype({ variant, motion }) {
  const [step, setStep] = useState(0);
  const [platforms, setPlatforms] = useState([]);
  const [keys, setKeys] = useState({});
  const [agent, setAgent] = useState({ type: "research", name: "", bio: "" });

  const cinematic = variant === "cinematic";
  // Minimal variant uses a much calmer, dimmer motion
  const motionIntensity = cinematic ? 1 : 0.35;
  // Motion now shows on every step, including sign-in
  const motionVisible = true;

  function toggle(id) {
    setPlatforms(p => p.includes(id) ? p.filter(x => x !== id) : [...p, id]);
  }
  function setKey(id, k, v) {
    setKeys(state => ({ ...state, [id]: { ...(state[id] || {}), [k]: v } }));
  }

  const screens = [
    <SignInScreen key="0" cinematic={cinematic}
      onDone={() => setStep(1)}/>,
    <PlatformStep key="1" cinematic={cinematic}
      selected={platforms} onToggle={toggle}
      onBack={() => setStep(0)} onNext={() => setStep(2)}/>,
    <KeysStep key="2" cinematic={cinematic}
      selected={platforms} keys={keys} onKey={setKey}
      onBack={() => setStep(1)} onNext={() => setStep(3)}/>,
    <AgentStep key="3" cinematic={cinematic}
      agent={agent} onChange={setAgent}
      onBack={() => setStep(2)} onNext={() => setStep(4)}/>,
    <HandoffStep key="4" cinematic={cinematic}
      agent={agent} onDone={() => setStep(0)}/>,
  ];

  return (
    <div style={{
      position: "relative",
      minHeight: 780,
      borderRadius: 24,
      overflow: "hidden",
      background: "#0a0a0f",
      border: "1px solid rgba(255,255,255,0.06)",
      isolation: "isolate",
    }}>
      {motionVisible && <MotionLayer style={motion} intensity={motionIntensity}/>}
      {cinematic && <SideRail step={step}/>}
      {cinematic && <CornerChrome/>}

      <div style={{
        position: "relative", zIndex: 2,
        minHeight: 780,
        display: "flex", alignItems: "center", justifyContent: "center",
        padding: cinematic ? "60px 40px 60px 200px" : "50px 24px",
      }}>
        <div key={step} style={{ animation: "screen-in .45s cubic-bezier(.2,.7,.2,1) both" }}>
          {screens[step]}
        </div>
      </div>

      {/* Dev step jumper — lives outside the scroll */}
      <div style={{
        position: "absolute", bottom: 16, left: "50%",
        transform: "translateX(-50%)", zIndex: 4,
        display: "flex", alignItems: "center", gap: 6,
        padding: "6px 10px", borderRadius: 9999,
        background: "rgba(10,10,15,0.75)",
        border: "1px solid rgba(255,255,255,0.06)",
        backdropFilter: "blur(10px)",
        fontSize: 9, fontWeight: 700, letterSpacing: "0.2em",
        textTransform: "uppercase", color: "#6b7280",
        fontFamily: "var(--font-mono)",
      }}>
        <span>jump</span>
        {[0,1,2,3,4].map(i => (
          <button key={i} onClick={() => setStep(i)} style={{
            width: 22, height: 22, borderRadius: 9999,
            background: step === i ? "#22c55e" : "transparent",
            color: step === i ? "#0a0a0f" : "#9ca3af",
            border: `1px solid ${step === i ? "#22c55e" : "rgba(255,255,255,0.10)"}`,
            cursor: "pointer", fontFamily: "inherit", fontSize: 9,
            fontWeight: 700,
          }}>{i+1}</button>
        ))}
      </div>
    </div>
  );
}

Object.assign(window, { Prototype, MotionLayer });
