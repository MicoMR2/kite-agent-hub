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
    DraggableChat,
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

