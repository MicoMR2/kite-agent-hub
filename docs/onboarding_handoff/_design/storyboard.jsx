/* global React, SignInScreen, PlatformStep, KeysStep, AgentStep, HandoffStep,
          MotionLayer, QuorumLogo, PLATFORMS */
const { useState: useSB } = React;

/* Storyboard — renders every frame in a scrollable vertical stack
   so the design can be reviewed end-to-end at a glance. */
function Storyboard({ variant, motion }) {
  const cinematic = variant === "cinematic";
  // Mock state used across every frame so the storyboard looks "lived-in"
  const mockPlatforms = ["alpaca", "kalshi"];
  const mockKeys = { alpaca: { kid: "ALPACA-PK7Z2Q81", sec: "••••••••" } };
  const mockAgent = {
    type: "research",
    name: "Research-Scout-01",
    bio: "Watch SPY and QQQ plus the Kalshi fed-rate markets. Flag divergences on the 15m chart. Terse updates, no fluff.",
  };

  const frames = [
    { title: "01 · Sign up",       sub: "Lowest-friction entry. Email or Google.",
      el: <SignInScreen cinematic={cinematic} onDone={() => {}}/> },
    { title: "02 · Pick venues",   sub: "Multi-select. Optional. Continue is enabled after any one is picked.",
      el: <PlatformStep cinematic={cinematic} selected={mockPlatforms} onToggle={() => {}} onNext={() => {}} onBack={() => {}}/> },
    { title: "03 · Connect keys",  sub: "Per-platform drill-in with live test-connection. Skippable.",
      el: <KeysStep cinematic={cinematic} selected={mockPlatforms} keys={mockKeys} onKey={() => {}} onNext={() => {}} onBack={() => {}}/> },
    { title: "04 · Create agent",  sub: "Research + Conversational available. Trading gated behind wallet.",
      el: <AgentStep cinematic={cinematic} agent={mockAgent} onChange={() => {}} onNext={() => {}} onBack={() => {}}/> },
    { title: "05 · Claude Code",   sub: "Copy-key + animated terminal demo. Next-step nudge to trading.",
      el: <HandoffStep cinematic={cinematic} agent={mockAgent} onDone={() => {}}/> },
  ];

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 48, paddingBottom: 60 }}>
      {frames.map((f, i) => (
        <div key={i} data-screen-label={f.title}>
          <div style={{
            display: "flex", alignItems: "baseline", gap: 14,
            marginBottom: 14, paddingLeft: 4,
          }}>
            <span style={{
              fontSize: 10, fontWeight: 700, letterSpacing: "0.2em",
              textTransform: "uppercase", color: "#22c55e",
              fontFamily: "var(--font-mono)",
            }}>{f.title}</span>
            <span style={{ fontSize: 12, color: "#9ca3af", fontWeight: 300 }}>
              {f.sub}
            </span>
            <span style={{ flex: 1, height: 1, background: "rgba(255,255,255,0.06)" }}/>
          </div>
          <div style={{
            position: "relative",
            borderRadius: 20,
            overflow: "hidden",
            background: "#0a0a0f",
            border: "1px solid rgba(255,255,255,0.06)",
            minHeight: 620,
            isolation: "isolate",
          }}>
            <MotionLayer style={motion} intensity={cinematic ? 0.85 : 0.3}/>
            <div style={{
              position: "relative", zIndex: 2,
              padding: "50px 30px",
              display: "flex", alignItems: "center", justifyContent: "center",
              minHeight: 620,
            }}>
              {f.el}
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

Object.assign(window, { Storyboard });
