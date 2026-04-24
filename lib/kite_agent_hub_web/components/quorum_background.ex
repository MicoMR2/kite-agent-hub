defmodule KiteAgentHubWeb.Components.QuorumBackground do
  @moduledoc """
  Full-bleed animated SVG used behind the onboarding flow and sign-in
  screen. Mirrors the dense Quorum composition from
  docs/onboarding_handoff/_design/motion.jsx — nine colored perimeter
  nodes exchanging data with a central decision node, cross-links
  between perimeter pairs, rotating grid rings, orbit belts, and
  traveling data packets.

  Pure SVG — no JS, no LV state. The parent just renders it and it
  runs. All motion is declarative via `<animate>`, `<animateTransform>`,
  and `<animateMotion>` so it plays even when JS is disabled. Browsers
  that honor `prefers-reduced-motion` pause the CSS-driven `mq-orbit`
  and `mq-dash` keyframe animations (declared in assets/css/app.css);
  the SVG-declared animations are paused via `<set>` inside the same
  media context below.

  aria-hidden — decorative only.
  """

  use Phoenix.Component

  @perimeter [
    %{x: 12, y: 18, c: "#60a5fa", d: 0.0},
    %{x: 88, y: 14, c: "#c084fc", d: 0.6},
    %{x: 92, y: 58, c: "#22c55e", d: 1.2},
    %{x: 68, y: 94, c: "#60a5fa", d: 1.8},
    %{x: 28, y: 88, c: "#c084fc", d: 2.4},
    %{x: 8, y: 52, c: "#22c55e", d: 3.0},
    %{x: 50, y: 8, c: "#ffffff", d: 3.6},
    %{x: 78, y: 34, c: "#60a5fa", d: 4.2},
    %{x: 22, y: 30, c: "#22c55e", d: 4.8}
  ]

  # Index pairs for the cross-link lines drawn between perimeter nodes.
  @cross_links [{0, 2}, {1, 5}, {3, 7}, {4, 8}, {0, 6}, {2, 4}]

  @grid_rings [10, 18, 26, 34, 42]
  @orbit_radii [14, 22, 30, 38]
  @pulse_rings [3, 5, 7]

  def background(assigns) do
    assigns =
      assigns
      |> assign_new(:class, fn -> "" end)
      |> assign(:perimeter, @perimeter)
      |> assign(:cross_links, @cross_links)
      |> assign(:grid_rings, @grid_rings)
      |> assign(:orbit_radii, @orbit_radii)
      |> assign(:pulse_rings, @pulse_rings)

    ~H"""
    <div class={"absolute inset-0 pointer-events-none overflow-hidden #{@class}"} aria-hidden="true">
      <svg
        class="absolute inset-0 w-full h-full"
        viewBox="0 0 100 100"
        preserveAspectRatio="xMidYMid slice"
        style="opacity: 0.95;"
      >
        <defs>
          <radialGradient id="mq-glow" cx="50%" cy="50%" r="50%">
            <stop offset="0%" stop-color="#22c55e" stop-opacity="0.35" />
            <stop offset="45%" stop-color="#22c55e" stop-opacity="0.10" />
            <stop offset="100%" stop-color="#22c55e" stop-opacity="0" />
          </radialGradient>

          <%= for {p, i} <- Enum.with_index(@perimeter) do %>
            <linearGradient
              id={"mq-r-#{i}"}
              x1={p.x}
              y1={p.y}
              x2="50"
              y2="50"
              gradientUnits="userSpaceOnUse"
            >
              <stop offset="0%" stop-color={p.c} stop-opacity="0" />
              <stop offset="70%" stop-color={p.c} stop-opacity="0.55" />
              <stop offset="100%" stop-color={p.c} stop-opacity="1" />
            </linearGradient>
          <% end %>
        </defs>

        <%!-- ambient halo --%>
        <circle cx="50" cy="50" r="42" fill="url(#mq-glow)">
          <animate attributeName="r" values="36;48;36" dur="6s" repeatCount="indefinite" />
        </circle>

        <%!-- slowly rotating grid rings --%>
        <%= for {r, i} <- Enum.with_index(@grid_rings) do %>
          <circle
            cx="50"
            cy="50"
            r={r}
            fill="none"
            stroke="rgba(255,255,255,0.05)"
            stroke-width="0.12"
            stroke-dasharray={if rem(i, 2) == 0, do: "0.5 1.5", else: "1 2.5"}
          >
            <animateTransform
              attributeName="transform"
              type="rotate"
              from={"#{i * 20} 50 50"}
              to={"#{i * 20 + 360} 50 50"}
              dur={"#{60 + i * 15}s"}
              repeatCount="indefinite"
            />
          </circle>
        <% end %>

        <%!-- orbit belts with colored beads, some reverse direction --%>
        <%= for {r, i} <- Enum.with_index(@orbit_radii) do %>
          <g style={
            "transform-origin: 50px 50px; animation: mq-orbit #{14 + i * 6}s linear infinite#{if rem(i, 2) == 1, do: " reverse", else: ""};"
          }>
            <circle cx={50 + r} cy="50" r="0.5" fill="#22c55e" opacity="0.7" />
            <circle cx={50 - r * 0.8} cy={50 + r * 0.6} r="0.35" fill="#60a5fa" opacity="0.5" />
            <circle cx={50 + r * 0.3} cy={50 - r * 0.85} r="0.3" fill="#c084fc" opacity="0.5" />
          </g>
        <% end %>

        <%!-- cross-links between perimeter nodes --%>
        <%= for {{a, b}, i} <- Enum.with_index(@cross_links) do %>
          <% pa = Enum.at(@perimeter, a) %>
          <% pb = Enum.at(@perimeter, b) %>
          <line
            x1={pa.x}
            y1={pa.y}
            x2={pb.x}
            y2={pb.y}
            stroke="rgba(255,255,255,0.06)"
            stroke-width="0.1"
            stroke-dasharray="0.8 1.4"
            style={"animation: mq-dash #{5 + i}s linear infinite;"}
          />
        <% end %>

        <%!-- rays to center + traveling data packets + pulsing perimeter nodes --%>
        <%= for {p, i} <- Enum.with_index(@perimeter) do %>
          <g>
            <line
              x1={p.x}
              y1={p.y}
              x2="50"
              y2="50"
              stroke={"url(#mq-r-#{i})"}
              stroke-width="0.35"
              stroke-dasharray="3 4"
              style={
                "animation: mq-dash #{2.8 + rem(i, 3) * 0.4}s linear infinite; animation-delay: #{p.d}s;"
              }
            />
            <%!-- traveling data packet --%>
            <circle r="0.55" fill={p.c} style={"filter: drop-shadow(0 0 1.5px #{p.c});"}>
              <animateMotion
                dur={"#{3 + rem(i, 3) * 0.5}s"}
                repeatCount="indefinite"
                begin={"#{p.d}s"}
                path={"M#{p.x} #{p.y} L50 50"}
              />
            </circle>
            <%!-- node --%>
            <circle
              cx={p.x}
              cy={p.y}
              r="0.9"
              fill={p.c}
              style={"filter: drop-shadow(0 0 2.5px #{p.c});"}
            >
              <animate
                attributeName="r"
                values="0.8;1.4;0.8"
                dur="2.4s"
                begin={"#{p.d}s"}
                repeatCount="indefinite"
              />
            </circle>
            <%!-- node halo ring --%>
            <circle
              cx={p.x}
              cy={p.y}
              r="1.8"
              fill="none"
              stroke={p.c}
              stroke-opacity="0.25"
              stroke-width="0.1"
            />
          </g>
        <% end %>

        <%!-- center decision node with expanding pulse rings --%>
        <%= for {r, i} <- Enum.with_index(@pulse_rings) do %>
          <circle cx="50" cy="50" r={r} fill="none" stroke="#22c55e" stroke-width="0.15">
            <animate
              attributeName="r"
              values={"#{r};#{r + 6};#{r}"}
              dur="3s"
              begin={"#{i * 0.4}s"}
              repeatCount="indefinite"
            />
            <animate
              attributeName="stroke-opacity"
              values="0.4;0;0.4"
              dur="3s"
              begin={"#{i * 0.4}s"}
              repeatCount="indefinite"
            />
          </circle>
        <% end %>

        <%!-- central core --%>
        <circle cx="50" cy="50" r="2.2" fill="#22c55e" style="filter: drop-shadow(0 0 4px #22c55e);">
          <animate attributeName="r" values="1.8;2.6;1.8" dur="2s" repeatCount="indefinite" />
        </circle>
      </svg>
    </div>
    """
  end
end
