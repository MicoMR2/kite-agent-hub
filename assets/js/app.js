// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/kite_agent_hub"
import topbar from "../vendor/topbar"
import anime from "../vendor/anime.es"

const ScrollBottom = {
  mounted() { this.el.scrollTop = this.el.scrollHeight },
  updated() { this.el.scrollTop = this.el.scrollHeight }
}

// LocalTime — render a server-provided UTC ISO timestamp in the viewer's
// local timezone. The server puts the raw ISO string in data-iso and an
// optional data-format of "time" (HH:mm) or "datetime" (Mon d HH:mm).
// Keeps UTC as the single source of truth server-side; only the display
// layer localizes.
const LocalTime = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    const iso = this.el.dataset.iso
    if (!iso) return
    const d = new Date(iso)
    if (isNaN(d.getTime())) return
    const fmt = this.el.dataset.format || "time"
    if (fmt === "datetime") {
      const month = d.toLocaleString("en-US", { month: "short" })
      const day = d.getDate()
      const hh = String(d.getHours()).padStart(2, "0")
      const mm = String(d.getMinutes()).padStart(2, "0")
      this.el.textContent = `${month} ${day} ${hh}:${mm}`
    } else {
      const hh = String(d.getHours()).padStart(2, "0")
      const mm = String(d.getMinutes()).padStart(2, "0")
      this.el.textContent = `${hh}:${mm}`
    }
  }
}

const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.text
      navigator.clipboard.writeText(text).then(() => {
        const original = this.el.innerHTML
        this.el.innerHTML = '<span class="text-xs font-black uppercase tracking-widest">Copied!</span>'
        setTimeout(() => { this.el.innerHTML = original }, 2000)
      })
    })
  }
}

// ChatInputClear — listen for a server-pushed "clear-chat-input" event
// and reset the input's .value property. The controlled value attribute
// alone doesn't reliably re-sync the displayed text after the user has
// typed, so we clear the property directly.
const ChatInputClear = {
  mounted() {
    this.handleEvent("clear-chat-input", () => {
      this.el.value = ""
    })
  }
}

// QuickTradeForm — intercepts the Quick Trade form submit to honor the
// "do not ask me again" preference stored in localStorage. When the
// flag is set, the form posts directly to forex_quick_trade (skipping
// the confirmation modal). When the flag is unset, the form posts to
// forex_quick_trade_review which opens the modal.
//
// The form template uses phx-submit="forex_quick_trade_review" by
// default; this hook flips that submit target client-side based on
// localStorage so a stale page-render does not show the modal to a
// user who already opted out.
const QuickTradeForm = {
  mounted() {
    this.update()
  },
  updated() {
    this.update()
  },
  update() {
    const skip = localStorage.getItem("kah_skip_quick_trade_confirm") === "true"
    this.el.setAttribute("phx-submit", skip ? "forex_quick_trade" : "forex_quick_trade_review")
  }
}

// QuickTradeConfirm — when the modal Confirm button is clicked, persist
// the "do not ask me again" checkbox state to localStorage BEFORE the
// LiveView event fires. The actual order placement still goes through
// LiveView (forex_quick_trade_confirm); this hook just side-effects
// localStorage so future submits skip the modal.
const QuickTradeConfirm = {
  mounted() {
    this.el.addEventListener("click", () => {
      const cb = document.getElementById("kah-skip-confirm-checkbox")
      if (cb && cb.checked) {
        localStorage.setItem("kah_skip_quick_trade_confirm", "true")
      }
    })
  }
}

// WordCycle — rotate an element's text through a list with a 200ms fade.
// Reads `data-words` (comma-separated) and `data-interval` (ms, default 2500).
// The element renders the word itself; the suffix (e.g. ".") is preserved
// from the initial textContent so we don't strip punctuation.
const WordCycle = {
  mounted() {
    const words = (this.el.dataset.words || "").split(",").map((s) => s.trim()).filter(Boolean)
    if (words.length < 2) return
    const interval = parseInt(this.el.dataset.interval || "2500", 10)
    const initial = this.el.textContent.trim()
    const tail = (initial.match(/[\.\!\?,;:…]+$/) || [""])[0]
    let i = 0
    this.el.style.transition = "opacity 200ms ease"
    this._timer = setInterval(() => {
      this.el.style.opacity = "0"
      setTimeout(() => {
        i = (i + 1) % words.length
        this.el.textContent = words[i] + tail
        this.el.style.opacity = "1"
      }, 200)
    }, interval)
  },
  destroyed() { clearInterval(this._timer) }
}

// Magnetic — subtly translate an element toward the cursor on hover.
// Used on the landing CTAs to give a premium tactile feel without a JS
// animation lib. Strength is keyed on `data-magnetic-strength` (default 18px).
const Magnetic = {
  mounted() {
    const max = parseFloat(this.el.dataset.magneticStrength || "18")
    const reset = () => { this.el.style.transform = "" }
    this._onMove = (e) => {
      const r = this.el.getBoundingClientRect()
      const dx = ((e.clientX - r.left) / r.width  - 0.5) * 2
      const dy = ((e.clientY - r.top)  / r.height - 0.5) * 2
      this.el.style.transform = `translate3d(${dx * max}px, ${dy * max}px, 0)`
    }
    this._onLeave = reset
    this.el.addEventListener("mousemove", this._onMove)
    this.el.addEventListener("mouseleave", this._onLeave)
    this.el.style.transition = "transform 220ms cubic-bezier(0.2, 0.8, 0.2, 1)"
  },
  destroyed() {
    this.el.removeEventListener("mousemove", this._onMove)
    this.el.removeEventListener("mouseleave", this._onLeave)
  }
}

// RevealOnScroll — IntersectionObserver-driven entrance animation.
// Starts the element with `kah-reveal` (opacity 0, 18px translate-y) and
// removes the class once 18% of the element is on-screen.
const RevealOnScroll = {
  _reveal() {
    this.el.classList.remove("kah-reveal")
    if (this._failsafe) { clearTimeout(this._failsafe); this._failsafe = null }
    if (this._io) { this._io.disconnect(); this._io = null }
  },
  mounted() {
    // Safety net: regardless of observer state, ensure the section is
    // visible within 1.2s of hook mount. Covers slow JS load, fast
    // back-forward nav, and any scenario where the IO callback never
    // fires for the element's current position.
    this._failsafe = setTimeout(() => this._reveal(), 1200)
    const rect = this.el.getBoundingClientRect()
    // Already at-or-above the viewport at mount time — reveal now;
    // IntersectionObserver does not retroactively fire for these.
    if (rect.top < window.innerHeight) { this._reveal(); return }
    if (typeof IntersectionObserver === "undefined") { this._reveal(); return }
    this._io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => { if (entry.isIntersecting) this._reveal() })
    }, { threshold: 0.18 })
    this._io.observe(this.el)
  },
  destroyed() {
    if (this._failsafe) clearTimeout(this._failsafe)
    if (this._io) this._io.disconnect()
  }
}

// ThemeCycle — three-state toggle (system → light → dark → system).
// Reads the current mode from data-theme-mode on <html> (written by
// the inline theme-init script in root.html.heex), advances to the
// next state, and fires phx:set-theme via a temporary data-phx-theme
// node so the existing handler in root.html.heex applies it.
const ThemeCycle = {
  _order: ["system", "light", "dark"],
  _next(current) {
    const i = this._order.indexOf(current)
    return this._order[(i + 1) % this._order.length]
  },
  _syncIcon() {
    const mode = document.documentElement.getAttribute("data-theme-mode") || "system"
    const light = this.el.querySelector(".kah-theme-icon-light")
    const dark = this.el.querySelector(".kah-theme-icon-dark")
    const sys = this.el.querySelector(".kah-theme-icon-system")
    if (light && dark && sys) {
      light.classList.toggle("hidden", mode !== "light")
      dark.classList.toggle("hidden", mode !== "dark")
      sys.classList.toggle("hidden", mode !== "system")
    }
  },
  mounted() {
    this._syncIcon()
    this._onClick = () => {
      const current = document.documentElement.getAttribute("data-theme-mode") || "system"
      const next = this._next(current)
      // The inline theme-init listens for phx:set-theme on a node carrying
      // data-phx-theme. Re-use that contract.
      const event = new CustomEvent("phx:set-theme", { bubbles: true })
      this.el.setAttribute("data-phx-theme", next)
      this.el.dispatchEvent(event)
      this._syncIcon()
    }
    this.el.addEventListener("click", this._onClick)
  },
  destroyed() {
    if (this._onClick) this.el.removeEventListener("click", this._onClick)
  }
}

// DraggableChat — turns the chat popup into a freely moveable + resizable
// panel. Drag from any [data-drag-handle] child; resize via the native
// CSS resize handle on the container. Position is persisted in
// sessionStorage so LiveView re-renders don't snap the panel back to
// bottom-right. A `chat:reset-position` window event clears the saved
// position and returns the panel to its default corner.
const STORAGE_KEY = "chat-panel-position"

const DraggableChat = {
  mounted() {
    this._dragging = false
    this._offsetX = 0
    this._offsetY = 0

    this._restorePosition()

    // If no saved position, convert the default bottom/right anchor into
    // explicit left/top coordinates. Native `resize: both` only resizes
    // toward the bottom-right corner, so a bottom-right-anchored element
    // can't grow naturally. Switching to top/left lets CSS resize work.
    if (!this.el.style.left && !this.el.style.top) {
      const rect = this.el.getBoundingClientRect()
      this.el.style.left = `${rect.left}px`
      this.el.style.top = `${rect.top}px`
      this.el.style.right = "auto"
      this.el.style.bottom = "auto"
    }

    this._onDown = (e) => {
      const handle = e.target.closest("[data-drag-handle]")
      if (!handle || !this.el.contains(handle)) return
      // Ignore drags that originate on interactive header controls so
      // clicks on the close / reset / invite buttons still work.
      if (e.target.closest("button, a, input, select, textarea")) return
      const rect = this.el.getBoundingClientRect()
      this._offsetX = e.clientX - rect.left
      this._offsetY = e.clientY - rect.top
      this._dragging = true
      this.el.style.transition = "none"
      handle.style.cursor = "grabbing"
      e.preventDefault()
    }

    this._onMove = (e) => {
      if (!this._dragging) return
      const w = this.el.offsetWidth
      const h = this.el.offsetHeight
      let x = e.clientX - this._offsetX
      let y = e.clientY - this._offsetY
      // Clamp to viewport so the panel can't be dragged off-screen.
      x = Math.max(0, Math.min(window.innerWidth - w, x))
      y = Math.max(0, Math.min(window.innerHeight - h, y))
      this.el.style.left = `${x}px`
      this.el.style.top = `${y}px`
      this.el.style.right = "auto"
      this.el.style.bottom = "auto"
    }

    this._onUp = () => {
      if (!this._dragging) return
      this._dragging = false
      this.el.style.transition = ""
      const handle = this.el.querySelector("[data-drag-handle]")
      if (handle) handle.style.cursor = ""
      this._savePosition()
    }

    this._onReset = () => {
      sessionStorage.removeItem(STORAGE_KEY)
      this.el.style.left = ""
      this.el.style.top = ""
      this.el.style.right = ""
      this.el.style.bottom = ""
      this.el.style.width = ""
      this.el.style.height = ""
    }

    this.el.addEventListener("pointerdown", this._onDown)
    window.addEventListener("pointermove", this._onMove)
    window.addEventListener("pointerup", this._onUp)
    window.addEventListener("chat:reset-position", this._onReset)
  },

  updated() {
    this._restorePosition()
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this._onDown)
    window.removeEventListener("pointermove", this._onMove)
    window.removeEventListener("pointerup", this._onUp)
    window.removeEventListener("chat:reset-position", this._onReset)
  },

  _savePosition() {
    try {
      sessionStorage.setItem(STORAGE_KEY, JSON.stringify({
        left: this.el.style.left,
        top: this.el.style.top,
        width: this.el.style.width,
        height: this.el.style.height
      }))
    } catch (_) { /* private mode, ignore */ }
  },

  _restorePosition() {
    try {
      const raw = sessionStorage.getItem(STORAGE_KEY)
      if (!raw) return
      const pos = JSON.parse(raw)
      if (pos.left) this.el.style.left = pos.left
      if (pos.top) this.el.style.top = pos.top
      if (pos.left || pos.top) {
        this.el.style.right = "auto"
        this.el.style.bottom = "auto"
      }
      if (pos.width) this.el.style.width = pos.width
      if (pos.height) this.el.style.height = pos.height
    } catch (_) { /* corrupt storage, ignore */ }
  }
}

// CountUp — anime.js-driven numeric count-up. Targets a number via
// `data-target` (Number-coercible); optional `data-decimals` (default 2)
// and `data-prefix` (e.g. "$") shape the formatted output.
//
// When the parent re-renders (LV broadcasts a broker refresh, the user
// switches tabs and back, etc.), the hook re-mounts. On remount we read
// the element's current textContent as the starting point so we don't
// animate from 0 every refresh — a tight refresh cadence (Forex tab
// refreshes every 10s) used to make the hero look like the page was
// reloading. The hook also short-circuits when data-target hasn't
// actually changed since the last run.
const CountUp = {
  mounted() {
    this._lastTarget = this._readCurrent()
    this._run()
  },
  updated() { this._run() },
  _readCurrent() {
    // Strip currency symbols / sign chars / commas; leave digits, dot,
    // minus. Returns null if the existing textContent isn't a parseable
    // number (first paint case where the server-rendered value is
    // "Generating...", "—", etc.).
    const raw = (this.el.textContent || "").replace(/[^\d.\-]/g, "")
    if (raw === "" || raw === "-" || raw === ".") return null
    const n = Number(raw)
    return Number.isNaN(n) ? null : n
  },
  _run() {
    const targetStr = this.el.dataset.target
    if (targetStr === undefined || targetStr === null || targetStr === "") return
    const target = Number(targetStr)
    if (Number.isNaN(target)) return
    if (this._lastTarget !== null && Math.abs(target - this._lastTarget) < 0.0001) return
    const decimals = Number(this.el.dataset.decimals ?? 2)
    const prefix = this.el.dataset.prefix ?? ""
    const from = this._lastTarget ?? 0
    const obj = { v: from }
    this._lastTarget = target
    anime({
      targets: obj,
      v: target,
      duration: 900,
      easing: "easeOutCubic",
      update: () => {
        const n = Number(obj.v).toFixed(decimals)
        // Tabular-num friendly: split sign and absolute value so the
        // existing template-side sign handling (▲/▼ pill) stays intact.
        this.el.textContent = `${prefix}${n}`
      }
    })
  }
}

// DonutChart — client-side hover interactivity for the portfolio donut.
// Replaces a server-side `phx-mouseenter` round-trip per Phorari 9982.
// Reads broker data from `data-*` attributes set in HEEx (server-trusted),
// updates the donut hole + arcs + cards locally with anime.js.
// CyberSec 9983: writes only via textContent / classList / setAttribute —
// never innerHTML.
const DonutChart = {
  mounted() { this._bind() },

  // LiveView patches the DOM in place when broker data streams in
  // (Alpaca/Kalshi/Polymarket/Forex load asynchronously after mount).
  // The arcs + cards inside the hook container get replaced, so the
  // listeners attached in `_bind()` end up on garbage nodes. Re-bind
  // on every patch to keep hover working as values fill in.
  updated() { this._bind() },

  destroyed() {
    if (!this._listeners) return
    this._listeners.forEach(([el, ev, fn]) => el.removeEventListener(ev, fn))
    this._listeners = []
  },

  _bind() {
    // Tear down any prior listeners before re-attaching (safe across
    // both initial mount and LV patches).
    if (this._listeners) {
      this._listeners.forEach(([el, ev, fn]) => el.removeEventListener(ev, fn))
    }
    this._listeners = []
    this._activeKey = null

    this.arcs = Array.from(this.el.querySelectorAll("[data-arc]"))
    this.cards = Array.from(this.el.querySelectorAll("[data-card]"))
    this.holeDefault = this.el.querySelector("[data-donut-hole-default]")
    this.holeHovered = this.el.querySelector("[data-donut-hole-hovered]")
    this.holeLabel = this.el.querySelector("[data-hole-label]")
    this.holeValue = this.el.querySelector("[data-hole-value]")
    this.holePct = this.el.querySelector("[data-hole-pct]")
    this.holePnl = this.el.querySelector("[data-hole-pnl]")

    this.cards.forEach(card => {
      const key = card.dataset.card
      const onEnter = () => this._enter(key)
      const onLeave = () => this._leave()
      card.addEventListener("pointerenter", onEnter)
      card.addEventListener("pointerleave", onLeave)
      this._listeners.push([card, "pointerenter", onEnter], [card, "pointerleave", onLeave])
    })

    this.arcs.forEach(arc => {
      const key = arc.dataset.arc
      const onEnter = () => this._enter(key)
      const onLeave = () => this._leave()
      arc.addEventListener("pointerenter", onEnter)
      arc.addEventListener("pointerleave", onLeave)
      this._listeners.push([arc, "pointerenter", onEnter], [arc, "pointerleave", onLeave])
    })
  },

  _enter(key) {
    if (this._activeKey === key) return
    this._activeKey = key

    const hoveredCard = this.cards.find(c => c.dataset.card === key)
    if (!hoveredCard) return
    const color = hoveredCard.dataset.color

    // Hole content swap. textContent only — never innerHTML.
    if (this.holeDefault && this.holeHovered) {
      this.holeDefault.classList.add("hidden")
      this.holeHovered.classList.remove("hidden")
    }
    if (this.holeLabel) {
      this.holeLabel.textContent = hoveredCard.dataset.label || ""
      this.holeLabel.style.color = color
    }
    if (this.holeValue) this.holeValue.textContent = hoveredCard.dataset.value || ""
    if (this.holePct) {
      this.holePct.textContent = `${hoveredCard.dataset.pct}% of total`
      this.holePct.style.color = color
    }
    if (this.holePnl) {
      const pnl = hoveredCard.dataset.pnl || ""
      const sign = hoveredCard.dataset.pnlSign || "+"
      this.holePnl.textContent = pnl
      this.holePnl.style.color = sign === "+" ? "#22c55e" : "#ef4444"
    }

    // Arcs: scale up the hovered one + glow, dim others.
    this.arcs.forEach(arc => {
      const isHovered = arc.dataset.arc === key
      anime.remove(arc)
      if (isHovered) {
        arc.style.filter = `drop-shadow(0 0 10px ${color})`
        anime({ targets: arc, scale: 1.06, opacity: 1, duration: 200, easing: "easeOutCubic" })
      } else {
        arc.style.filter = ""
        anime({ targets: arc, scale: 1.0, opacity: 0.4, duration: 200, easing: "easeOutCubic" })
      }
    })

    // Cards: matching card gets ring + scale, others stay neutral.
    this.cards.forEach(card => {
      if (card.dataset.card === key) {
        card.style.boxShadow = `0 0 0 2px ${color}, 0 0 24px ${color}55`
        card.style.transform = "scale(1.015)"
      } else {
        card.style.boxShadow = ""
        card.style.transform = "scale(1.0)"
        card.style.opacity = "0.65"
      }
    })
  },

  _leave() {
    if (!this._activeKey) return
    this._activeKey = null

    if (this.holeDefault && this.holeHovered) {
      this.holeHovered.classList.add("hidden")
      this.holeDefault.classList.remove("hidden")
    }

    this.arcs.forEach(arc => {
      anime.remove(arc)
      arc.style.filter = ""
      anime({ targets: arc, scale: 1.0, opacity: 1, duration: 200, easing: "easeOutCubic" })
    })

    this.cards.forEach(card => {
      card.style.boxShadow = ""
      card.style.transform = ""
      card.style.opacity = ""
    })
  }
}

// CrosshairChart — pointermove crosshair + tooltip for the forex
// instrument price chart. Reads pre-computed [{x, v, t}] points from
// the container's `data-points` attribute (server-encoded JSON; the
// hook never parses formatted DOM text — CyberSec 13769). All DOM
// writes happen via textContent / classList / setAttribute, no
// innerHTML.
const CrosshairChart = {
  mounted() { this._bind() },

  // LiveView re-renders this container whenever @forex_chart_price or
  // @forex_candles change (every 30s poll, plus on MID/BID/ASK toggle).
  // Re-bind so listeners attach to the fresh DOM nodes and the new
  // data-points payload.
  updated() { this._bind() },

  destroyed() {
    if (this._cleanup) this._cleanup()
  },

  _bind() {
    if (this._cleanup) this._cleanup()

    let points
    try {
      points = JSON.parse(this.el.dataset.points || "[]")
    } catch (e) {
      points = []
    }
    if (!Array.isArray(points) || points.length === 0) {
      this._cleanup = null
      return
    }

    const svg = this.el.querySelector("svg")
    if (!svg) return

    const crosshairLine = this.el.querySelector("[data-crosshair-x]")
    const tooltip = this.el.querySelector("[data-crosshair-tooltip]")
    const tooltipPrice = this.el.querySelector("[data-crosshair-price]")
    const tooltipTime = this.el.querySelector("[data-crosshair-time]")

    const VIEW_W = 700  // matches the SVG viewBox width in HEEx
    const PLOT_W = 640  // points are computed against this; right margin = price labels

    const onMove = ev => {
      const rect = svg.getBoundingClientRect()
      if (rect.width === 0) return
      const xRatio = (ev.clientX - rect.left) / rect.width
      const cursorX = Math.max(0, Math.min(PLOT_W, xRatio * VIEW_W))

      // Walk the (small) point list to find the nearest x.
      let nearest = points[0]
      let bestDelta = Math.abs(points[0].x - cursorX)
      for (let i = 1; i < points.length; i++) {
        const d = Math.abs(points[i].x - cursorX)
        if (d < bestDelta) { bestDelta = d; nearest = points[i] }
      }

      if (crosshairLine) {
        crosshairLine.setAttribute("x1", nearest.x)
        crosshairLine.setAttribute("x2", nearest.x)
        crosshairLine.classList.remove("hidden")
      }
      if (tooltip) tooltip.classList.remove("hidden")
      if (tooltipPrice) tooltipPrice.textContent = nearest.v
      if (tooltipTime) tooltipTime.textContent = nearest.t
    }

    const onLeave = () => {
      if (crosshairLine) crosshairLine.classList.add("hidden")
      if (tooltip) tooltip.classList.add("hidden")
    }

    svg.addEventListener("pointermove", onMove)
    svg.addEventListener("pointerleave", onLeave)
    this._cleanup = () => {
      svg.removeEventListener("pointermove", onMove)
      svg.removeEventListener("pointerleave", onLeave)
      this._cleanup = null
    }
  }
}

// FadeInStagger — anime.js entrance animation that lifts and fades in
// every immediate child of the hook element with a small per-element
// delay. Used for portfolio per-broker cards on mount.
const FadeInStagger = {
  mounted() {
    const targets = Array.from(this.el.children)
    if (targets.length === 0) return
    targets.forEach(el => {
      el.style.opacity = "0"
      el.style.transform = "translateY(8px)"
    })
    anime({
      targets,
      opacity: [0, 1],
      translateY: [8, 0],
      duration: 600,
      delay: anime.stagger(60),
      easing: "easeOutCubic"
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  // 10s gives WebSocket time to handshake on slower connections before
  // falling back to longpoll. The previous 2.5s caused most clients to
  // drop straight to longpoll, which combined with multi-machine
  // routing produced a constant reconnect loop.
  longPollFallbackMs: 10000,
  params: {_csrf_token: csrfToken},
  hooks: {
    ...colocatedHooks,
    ScrollBottom,
    CopyToClipboard,
    LocalTime,
    ChatInputClear,
    CountUp,
    CrosshairChart,
    DonutChart,
    DraggableChat,
    FadeInStagger,
    QuickTradeForm,
    QuickTradeConfirm,
    Magnetic,
    RevealOnScroll,
    ThemeCycle,
    WordCycle
  },
})

// Show progress bar on live navigation and form submits
// Brand-green topbar in both themes — the previous #29d blue washed
// out against the cream light-mode canvas and made page-loading
// invisible. #22c55e reads on dark AND light, matches CTAs.
topbar.config({barColors: {0: "#22c55e"}, barThickness: 3, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Only connect LiveSocket on pages with a LiveView mount point
// Prevents "We can't find the internet" banners on controller pages like /users/settings
if (document.querySelector("[data-phx-main]") || document.querySelector("[data-phx-session]")) {
  liveSocket.connect()
}

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

