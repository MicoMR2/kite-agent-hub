/* global React */
// Three full-bleed animated SVG backgrounds used behind the onboarding flow.
// Busier, denser version — more moving parts, more layers, more life.

/* ─────────────────────────────────────────────────────────────
   1) QUORUM — dense agent network with active signal exchange
   ───────────────────────────────────────────────────────────── */
function MotionQuorum({ intensity = 1 }) {
  // Many sender nodes around the perimeter firing into center + to each other.
  const perimeter = [
    { x: 12, y: 18, c: "#60a5fa", d: 0 },
    { x: 88, y: 14, c: "#c084fc", d: 0.6 },
    { x: 92, y: 58, c: "#22c55e", d: 1.2 },
    { x: 68, y: 94, c: "#60a5fa", d: 1.8 },
    { x: 28, y: 88, c: "#c084fc", d: 2.4 },
    { x: 8,  y: 52, c: "#22c55e", d: 3.0 },
    { x: 50, y: 8,  c: "#ffffff", d: 3.6 },
    { x: 78, y: 34, c: "#60a5fa", d: 4.2 },
    { x: 22, y: 30, c: "#22c55e", d: 4.8 },
  ];
  // Cross-links between pairs of nodes
  const links = [[0,2],[1,5],[3,7],[4,8],[0,6],[2,4]];

  return (
    <svg className="motion-root" viewBox="0 0 100 100"
         preserveAspectRatio="xMidYMid slice" style={{ opacity: 0.95 * intensity }}>
      <defs>
        <radialGradient id="mq-glow" cx="50%" cy="50%" r="50%">
          <stop offset="0%"  stopColor="#22c55e" stopOpacity="0.35"/>
          <stop offset="45%" stopColor="#22c55e" stopOpacity="0.10"/>
          <stop offset="100%" stopColor="#22c55e" stopOpacity="0"/>
        </radialGradient>
        {perimeter.map((p, i) => (
          <linearGradient key={i} id={`mq-r-${i}`} x1={p.x} y1={p.y} x2="50" y2="50" gradientUnits="userSpaceOnUse">
            <stop offset="0%"  stopColor={p.c} stopOpacity="0"/>
            <stop offset="70%" stopColor={p.c} stopOpacity="0.55"/>
            <stop offset="100%" stopColor={p.c} stopOpacity="1"/>
          </linearGradient>
        ))}
      </defs>

      {/* ambient halo */}
      <circle cx="50" cy="50" r="42" fill="url(#mq-glow)">
        <animate attributeName="r" values="36;48;36" dur="6s" repeatCount="indefinite"/>
      </circle>

      {/* grid rings */}
      {[10, 18, 26, 34, 42].map((r, i) => (
        <circle key={i} cx="50" cy="50" r={r} fill="none"
                stroke="rgba(255,255,255,0.05)" strokeWidth="0.12"
                strokeDasharray={i % 2 ? "0.5 1.5" : "1 2.5"}>
          <animateTransform attributeName="transform" type="rotate"
            from={`${i * 20} 50 50`} to={`${i * 20 + 360} 50 50`}
            dur={`${60 + i * 15}s`} repeatCount="indefinite"/>
        </circle>
      ))}

      {/* orbit belts */}
      {[14, 22, 30, 38].map((r, i) => (
        <g key={`o-${i}`} style={{
          transformOrigin: "50px 50px",
          animation: `mq-orbit ${14 + i * 6}s linear infinite ${i % 2 ? "reverse" : ""}`,
        }}>
          <circle cx={50 + r} cy="50"           r="0.5" fill="#22c55e" opacity="0.7"/>
          <circle cx={50 - r * 0.8} cy={50 + r * 0.6} r="0.35" fill="#60a5fa" opacity="0.5"/>
          <circle cx={50 + r * 0.3} cy={50 - r * 0.85} r="0.3" fill="#c084fc" opacity="0.5"/>
        </g>
      ))}

      {/* cross-links between perimeter nodes */}
      {links.map(([a, b], i) => {
        const pa = perimeter[a], pb = perimeter[b];
        return (
          <line key={`l-${i}`} x1={pa.x} y1={pa.y} x2={pb.x} y2={pb.y}
            stroke="rgba(255,255,255,0.05)" strokeWidth="0.1"
            strokeDasharray="0.8 1.4"
            style={{ animation: `mq-dash ${5 + i}s linear infinite` }}/>
        );
      })}

      {/* rays to center */}
      {perimeter.map((p, i) => (
        <g key={`ray-${i}`}>
          <line x1={p.x} y1={p.y} x2="50" y2="50"
            stroke={`url(#mq-r-${i})`} strokeWidth="0.35"
            strokeDasharray="3 4"
            style={{ animation: `mq-dash ${2.8 + (i % 3) * 0.4}s linear infinite`,
                     animationDelay: `${p.d}s` }}/>
          {/* traveling data packet */}
          <circle r="0.55" fill={p.c}
                  style={{ filter: `drop-shadow(0 0 1.5px ${p.c})` }}>
            <animateMotion dur={`${3 + (i % 3) * 0.5}s`} repeatCount="indefinite"
              begin={`${p.d}s`}
              path={`M${p.x} ${p.y} L50 50`}/>
          </circle>
          {/* node */}
          <circle cx={p.x} cy={p.y} r="0.9" fill={p.c}
                  style={{ filter: `drop-shadow(0 0 2.5px ${p.c})` }}>
            <animate attributeName="r" values="0.8;1.4;0.8" dur="2.4s"
                     begin={`${p.d}s`} repeatCount="indefinite"/>
          </circle>
          {/* node label tick */}
          <circle cx={p.x} cy={p.y} r="1.8" fill="none" stroke={p.c}
                  strokeOpacity="0.25" strokeWidth="0.1"/>
        </g>
      ))}

      {/* center decision node with pulsing rings */}
      {[3, 5, 7].map((r, i) => (
        <circle key={i} cx="50" cy="50" r={r} fill="none"
                stroke="#22c55e" strokeWidth="0.15">
          <animate attributeName="r" values={`${r};${r + 6};${r}`} dur="3s"
                   begin={`${i * 0.4}s`} repeatCount="indefinite"/>
          <animate attributeName="stroke-opacity" values="0.4;0;0.4" dur="3s"
                   begin={`${i * 0.4}s`} repeatCount="indefinite"/>
        </circle>
      ))}
      <circle cx="50" cy="50" r="2.2" fill="#22c55e"
              style={{ filter: "drop-shadow(0 0 4px #22c55e)" }}>
        <animate attributeName="r" values="1.8;2.6;1.8" dur="2s" repeatCount="indefinite"/>
      </circle>

      {/* scanning sweep */}
      <g style={{ transformOrigin: "50px 50px", animation: "mq-orbit 9s linear infinite" }}>
        <path d="M50 50 L50 8 A42 42 0 0 1 82 24 Z"
              fill="#22c55e" fillOpacity="0.04"/>
      </g>
    </svg>
  );
}

/* ─────────────────────────────────────────────────────────────
   2) BLOCKSTREAM — dense scrolling data with attestation flares
   ───────────────────────────────────────────────────────────── */
function MotionBlockstream({ intensity = 1 }) {
  const hashes = [
    "0x3f9d2e", "0x91a742", "0xbc1f08", "0x74ee19",
    "0x21b3d7", "0x5a88c1", "0x0eaf34", "0xdd7102",
    "0xcc4491", "0x7711ab", "0x880f2c", "0x1122ef",
    "0x33f01c", "0x4ab8e7", "0x9c2105", "0xff4411",
    "0x6d3a02", "0xb08211", "0x40fe77", "0x18cd33",
  ];
  const cols = [
    { x: 8,  dur: 20, offset: 0 },
    { x: 24, dur: 26, offset: -15 },
    { x: 40, dur: 22, offset: -5  },
    { x: 56, dur: 28, offset: -22 },
    { x: 72, dur: 24, offset: -10 },
    { x: 88, dur: 30, offset: -18 },
  ];
  // horizontal scanning lines
  const scans = [
    { y: 22, dur: 9,  dir: 1  },
    { y: 58, dur: 11, dir: -1 },
    { y: 82, dur: 8,  dir: 1  },
  ];

  return (
    <svg className="motion-root" viewBox="0 0 100 100"
         preserveAspectRatio="xMidYMid slice" style={{ opacity: 0.9 * intensity }}>
      <defs>
        <linearGradient id="mb-fade" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%"  stopColor="#0a0a0f" stopOpacity="1"/>
          <stop offset="12%" stopColor="#0a0a0f" stopOpacity="0"/>
          <stop offset="88%" stopColor="#0a0a0f" stopOpacity="0"/>
          <stop offset="100%" stopColor="#0a0a0f" stopOpacity="1"/>
        </linearGradient>
        <mask id="mb-mask"><rect width="100" height="100" fill="url(#mb-fade)"/></mask>
        <radialGradient id="mb-glow" cx="50%" cy="50%" r="55%">
          <stop offset="0%"  stopColor="#22c55e" stopOpacity="0.10"/>
          <stop offset="80%" stopColor="#22c55e" stopOpacity="0"/>
        </radialGradient>
      </defs>

      {/* faint grid */}
      {[20, 40, 60, 80].map((x, i) => (
        <line key={`gv-${i}`} x1={x} y1="0" x2={x} y2="100"
              stroke="rgba(255,255,255,0.025)" strokeWidth="0.08"/>
      ))}
      {[20, 40, 60, 80].map((y, i) => (
        <line key={`gh-${i}`} x1="0" y1={y} x2="100" y2={y}
              stroke="rgba(255,255,255,0.025)" strokeWidth="0.08"/>
      ))}

      <rect width="100" height="100" fill="url(#mb-glow)"/>

      {/* scrolling columns of hashes */}
      <g mask="url(#mb-mask)">
        {cols.map((c, ci) => (
          <g key={ci} style={{
            animation: `mb-scroll ${c.dur}s linear infinite`,
            animationDelay: `${c.offset}s`,
          }}>
            {hashes.concat(hashes).map((h, i) => {
              const y = 100 + i * 5;
              const isAttest = ((i + ci) % 6 === 2);
              const isFail = ((i + ci) % 11 === 4);
              return (
                <g key={i} transform={`translate(${c.x},${y})`}>
                  {isAttest ? (
                    <>
                      <rect x="-7" y="-1.5" width="14" height="3" rx="1.2"
                            fill="rgba(34,197,94,0.12)"
                            stroke="rgba(34,197,94,0.45)" strokeWidth="0.08"/>
                      <circle cx="-5" cy="0" r="0.4" fill="#22c55e"
                              style={{ filter: "drop-shadow(0 0 1px #22c55e)" }}/>
                      <text x="-3.5" y="0.5" fill="#22c55e" fontFamily="ui-monospace, monospace"
                            fontSize="1.3" fontWeight="700" letterSpacing="0.08">
                        ATTEST
                      </text>
                    </>
                  ) : isFail ? (
                    <text x="0" y="0.5" textAnchor="middle"
                          fill="rgba(239,68,68,0.55)"
                          fontFamily="ui-monospace, monospace"
                          fontSize="1.5">
                      {h} ✗
                    </text>
                  ) : (
                    <text x="0" y="0.5" textAnchor="middle"
                          fill={i % 3 === 0 ? "rgba(255,255,255,0.45)" : "rgba(255,255,255,0.22)"}
                          fontFamily="ui-monospace, monospace"
                          fontSize="1.4">
                      {h}
                    </text>
                  )}
                </g>
              );
            })}
          </g>
        ))}
      </g>

      {/* horizontal scanning lines */}
      {scans.map((s, i) => (
        <g key={`scan-${i}`} style={{
          animation: `mb-scan-${i} ${s.dur}s linear infinite`,
        }}>
          <line x1="0" x2="100" y1={s.y} y2={s.y}
                stroke="#22c55e" strokeOpacity="0.15" strokeWidth="0.08"/>
          <circle cx="0" cy={s.y} r="0.6" fill="#22c55e"
                  style={{ filter: "drop-shadow(0 0 2px #22c55e)" }}/>
        </g>
      ))}
      <style>{`
        @keyframes mb-scan-0 { from { transform: translateX(-10%); } to { transform: translateX(110%); } }
        @keyframes mb-scan-1 { from { transform: translateX(110%); } to { transform: translateX(-10%); } }
        @keyframes mb-scan-2 { from { transform: translateX(-10%); } to { transform: translateX(110%); } }
      `}</style>

      {/* block-height readout, top left */}
      <g transform="translate(4,6)">
        <rect x="-1.5" y="-2.2" width="20" height="3.2" rx="0.8"
              fill="rgba(0,0,0,0.4)" stroke="rgba(255,255,255,0.08)" strokeWidth="0.08"/>
        <circle cx="0" cy="-0.6" r="0.4" fill="#22c55e">
          <animate attributeName="opacity" values="1;0.3;1" dur="1.4s" repeatCount="indefinite"/>
        </circle>
        <text x="1.5" y="0" fill="rgba(255,255,255,0.6)" fontFamily="ui-monospace, monospace"
              fontSize="1.5" fontWeight="700" letterSpacing="0.1">
          BLOCK 8,241,603
        </text>
      </g>

      {/* side hairlines */}
      <line x1="0.4" y1="0" x2="0.4" y2="100" stroke="rgba(255,255,255,0.06)" strokeWidth="0.1"/>
      <line x1="99.6" y1="0" x2="99.6" y2="100" stroke="rgba(255,255,255,0.06)" strokeWidth="0.1"/>
    </svg>
  );
}

/* ─────────────────────────────────────────────────────────────
   3) KITE — multiple flying kites with constellation stars
   ───────────────────────────────────────────────────────────── */
function MotionKite({ intensity = 1 }) {
  // star constellation
  const stars = [
    {x: 8,  y: 12, r: 0.35}, {x: 22, y: 8,  r: 0.25},
    {x: 38, y: 18, r: 0.3 }, {x: 74, y: 10, r: 0.4 },
    {x: 88, y: 22, r: 0.3 }, {x: 6,  y: 44, r: 0.25},
    {x: 94, y: 48, r: 0.35}, {x: 12, y: 72, r: 0.3 },
    {x: 82, y: 78, r: 0.25}, {x: 64, y: 86, r: 0.35},
    {x: 32, y: 92, r: 0.3 }, {x: 50, y: 28, r: 0.2 },
  ];
  // three kites at different depths/positions
  const kites = [
    { cx: 30, cy: 34, size: 12, sway: 6,  speed: 10, color: "#22c55e", wind: 2 },
    { cx: 72, cy: 28, size: 16, sway: 8,  speed: 12, color: "#60a5fa", wind: 3 },
    { cx: 52, cy: 58, size: 22, sway: 10, speed: 8,  color: "#ffffff", wind: 4 },
  ];

  return (
    <svg className="motion-root" viewBox="0 0 100 100"
         preserveAspectRatio="xMidYMid slice" style={{ opacity: 0.9 * intensity }}>
      <defs>
        <radialGradient id="mk-glow" cx="50%" cy="40%" r="55%">
          <stop offset="0%"  stopColor="#22c55e" stopOpacity="0.12"/>
          <stop offset="80%" stopColor="#22c55e" stopOpacity="0"/>
        </radialGradient>
        <linearGradient id="mk-tether" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%"  stopColor="#22c55e" stopOpacity="0.6"/>
          <stop offset="100%" stopColor="#22c55e" stopOpacity="0"/>
        </linearGradient>
      </defs>

      <rect width="100" height="100" fill="url(#mk-glow)"/>

      {/* wind trails — diagonal dashed lines */}
      {[15, 30, 45, 60, 75, 90].map((y, i) => (
        <line key={`w-${i}`} x1="-10" y1={y} x2="110" y2={y - 5}
          stroke="rgba(255,255,255,0.04)" strokeWidth="0.1"
          strokeDasharray={`${1 + (i % 3)} ${2 + (i % 2)}`}
          style={{ animation: `mk-wind ${10 + i}s linear infinite`,
                   animationDelay: `${i * -1.3}s` }}/>
      ))}

      {/* twinkling stars */}
      {stars.map((s, i) => (
        <circle key={`s-${i}`} cx={s.x} cy={s.y} r={s.r} fill="#fff">
          <animate attributeName="opacity" values="0.2;0.9;0.2"
                   dur={`${2.4 + (i % 4) * 0.6}s`}
                   begin={`${i * 0.3}s`} repeatCount="indefinite"/>
        </circle>
      ))}

      {/* constellation links */}
      <g stroke="rgba(255,255,255,0.05)" strokeWidth="0.08">
        <line x1="8"  y1="12" x2="22" y2="8"/>
        <line x1="22" y1="8"  x2="38" y2="18"/>
        <line x1="74" y1="10" x2="88" y2="22"/>
        <line x1="12" y1="72" x2="32" y2="92"/>
        <line x1="64" y1="86" x2="82" y2="78"/>
      </g>

      {/* kites */}
      {kites.map((k, i) => (
        <g key={i} style={{
          transformOrigin: `${k.cx}px ${k.cy}px`,
          animation: `mk-drift-${i} ${k.speed}s ease-in-out infinite`,
        }}>
          {/* ghost outlines behind each kite */}
          {[0.3, 0.6].map((o, gi) => (
            <path key={gi}
              d={`M${k.cx} ${k.cy - k.size} L${k.cx + k.size*0.85} ${k.cy} L${k.cx} ${k.cy + k.size} L${k.cx - k.size*0.85} ${k.cy} Z`}
              fill="none"
              stroke={`rgba(255,255,255,${0.05 * (1 - o)})`}
              strokeWidth="0.12"
              transform={`translate(${-gi * 1.2} ${-gi * 0.8}) scale(${1 - gi * 0.08})`}
              style={{ transformOrigin: `${k.cx}px ${k.cy}px` }}/>
          ))}
          <path d={`M${k.cx} ${k.cy - k.size} L${k.cx + k.size*0.85} ${k.cy} L${k.cx} ${k.cy + k.size} L${k.cx - k.size*0.85} ${k.cy} Z`}
            fill={`${k.color}0a`}
            stroke={`rgba(255,255,255,${0.22})`} strokeWidth="0.2"/>
          <line x1={k.cx} y1={k.cy - k.size} x2={k.cx} y2={k.cy + k.size}
                stroke="rgba(255,255,255,0.14)" strokeWidth="0.1"/>
          <line x1={k.cx - k.size*0.85} y1={k.cy} x2={k.cx + k.size*0.85} y2={k.cy}
                stroke="rgba(255,255,255,0.14)" strokeWidth="0.1"/>
          <circle cx={k.cx} cy={k.cy - k.size} r="0.7" fill={k.color}
                  style={{ filter: `drop-shadow(0 0 1.5px ${k.color})` }}>
            <animate attributeName="r" values="0.6;1;0.6" dur="2.5s" repeatCount="indefinite"/>
          </circle>
          {/* tether */}
          <line x1={k.cx} y1={k.cy + k.size} x2={k.cx + k.wind} y2="100"
                stroke="url(#mk-tether)" strokeWidth="0.18"
                strokeDasharray="1 1.6"
                style={{ animation: "mk-tether 3s linear infinite" }}/>
        </g>
      ))}
      <style>{`
        @keyframes mk-drift-0 { 0%,100% { transform: translate(-1.5px,0) rotate(-3deg); }
                                50% { transform: translate(2px,-1.5px) rotate(2deg); } }
        @keyframes mk-drift-1 { 0%,100% { transform: translate(2px,-1px) rotate(3deg); }
                                50% { transform: translate(-2px,1px) rotate(-2deg); } }
        @keyframes mk-drift-2 { 0%,100% { transform: translate(-1px,0.5px) rotate(-1.5deg); }
                                50% { transform: translate(1.2px,-0.5px) rotate(1.8deg); } }
      `}</style>

      {/* altitude tick readouts on right edge */}
      {[20, 40, 60, 80].map((y, i) => (
        <g key={`alt-${i}`} transform={`translate(94,${y})`}>
          <line x1="0" x2="2" y1="0" y2="0"
                stroke="rgba(255,255,255,0.15)" strokeWidth="0.1"/>
          <text x="-1" y="0.4" textAnchor="end"
                fill="rgba(255,255,255,0.25)" fontFamily="ui-monospace, monospace"
                fontSize="1.3" letterSpacing="0.08">
            {(100 - y) * 10}m
          </text>
        </g>
      ))}
    </svg>
  );
}

Object.assign(window, { MotionQuorum, MotionBlockstream, MotionKite });
