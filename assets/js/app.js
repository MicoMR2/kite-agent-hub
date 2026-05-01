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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  // 10s gives WebSocket time to handshake on slower connections before
  // falling back to longpoll. The previous 2.5s caused most clients to
  // drop straight to longpoll, which combined with multi-machine
  // routing produced a constant reconnect loop.
  longPollFallbackMs: 10000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ScrollBottom, CopyToClipboard, LocalTime, ChatInputClear},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
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

