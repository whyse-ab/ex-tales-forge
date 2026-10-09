// The founders' pages: the landing page (/team, TalesForgeWeb.TeamLive) and
// the full presentation (/team/presentation, TalesForgeWeb.TeamPresentationLive).
// TeamAnchorRedirect forwards old /team#section links to the presentation;
// the rest are the animations.
//
// Everything here is decoration: the server renders the full, static page
// (every flow step lit, every bar at its size), and nothing is hidden until
// this code has decided motion is allowed. With prefers-reduced-motion the
// page root gets data-motion="reduce" and nothing moves; otherwise
// data-motion="full", sections fade in as they scroll into view, their bars
// grow (CSS, app.css "Founders' page"), and the d20 rolls through the change
// flow once, with a Replay button.

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)")

// Root hook: sets data-motion, reveals [data-reveal] sections in view, and
// runs the peeks (hover cards, see setupPeeks below).
export const TeamPage = {
  mounted() {
    this.mq = reducedMotion()
    this.onChange = () => this.apply()
    this.mq.addEventListener("change", this.onChange)
    this.apply()
    this.peeksCleanup = setupPeeks(this.el)
  },

  apply() {
    const reduce = this.mq.matches || !("IntersectionObserver" in window)
    this.el.dataset.motion = reduce ? "reduce" : "full"
    this.observer?.disconnect()
    const sections = this.el.querySelectorAll("[data-reveal]")

    if (reduce) {
      sections.forEach(s => s.classList.add("is-visible"))
      return
    }

    this.observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        entry.target.classList.add("is-visible")
        this.observer.unobserve(entry.target)
      }
    }, {rootMargin: "0px 0px -8% 0px", threshold: 0.02})

    sections.forEach(s => s.classList.contains("is-visible") || this.observer.observe(s))
  },

  destroyed() {
    this.observer?.disconnect()
    this.mq?.removeEventListener("change", this.onChange)
    this.peeksCleanup?.()
  },
}

// Peeks: the hover cards on the call-type pills (TalesForgeWeb.TeamPeek).
// A [data-peek] wrapper holds a [data-peek-trigger] button and its card; the
// card shows while the wrapper has data-open (Tailwind classes in the
// component), and the button's aria-expanded follows it.
//   - Mouse: opens on hover, closes on leaving (unless pinned).
//   - Keyboard: opens when the button gets focus, closes when focus leaves
//     the peek (unless pinned). Enter/Space pins it like a click.
//   - Tap or click on the button: pins it open, or closes it if pinned.
//   - Esc closes every peek and puts focus back on its button; a tap or click
//     outside closes pinned ones. One peek is open at a time.
// Motion (the fade) is CSS with motion-safe:, so reduced motion just snaps.
export const setupPeeks = root => {
  const all = () => root.querySelectorAll("[data-peek]")
  const peekOf = node => node instanceof Element ? node.closest("[data-peek]") : null
  const triggerOf = peek => peek.querySelector("[data-peek-trigger]")

  const open = (peek, pinned = false) => {
    all().forEach(other => other !== peek && close(other))
    peek.dataset.open = ""
    if (pinned) peek.dataset.pinned = ""
    triggerOf(peek)?.setAttribute("aria-expanded", "true")
  }

  const close = peek => {
    delete peek.dataset.open
    delete peek.dataset.pinned
    triggerOf(peek)?.setAttribute("aria-expanded", "false")
  }

  const isOpen = peek => "open" in peek.dataset
  const isPinned = peek => "pinned" in peek.dataset

  const onPointerOver = e => {
    const peek = peekOf(e.target)
    if (e.pointerType !== "mouse" || !peek || isOpen(peek) || "dismissed" in peek.dataset) return
    open(peek)
  }

  const onPointerOut = e => {
    const peek = peekOf(e.target)
    if (e.pointerType !== "mouse" || !peek || peek.contains(e.relatedTarget)) return
    delete peek.dataset.dismissed
    if (!isPinned(peek)) close(peek)
  }

  const onFocusIn = e => {
    const peek = peekOf(e.target)
    if (!peek || isOpen(peek) || !e.target.matches("[data-peek-trigger]:focus-visible")) return
    open(peek)
  }

  const onFocusOut = e => {
    const peek = peekOf(e.target)
    if (!peek || peek.contains(e.relatedTarget) || isPinned(peek)) return
    close(peek)
  }

  const onClick = e => {
    const trigger = e.target instanceof Element ? e.target.closest("[data-peek-trigger]") : null

    if (trigger) {
      const peek = peekOf(trigger)
      if (!peek) return

      if (isPinned(peek)) {
        close(peek)
        if (peek.matches(":hover")) peek.dataset.dismissed = ""
      } else {
        open(peek, true)
      }

      return
    }

    const inside = peekOf(e.target)
    all().forEach(peek => peek !== inside && isPinned(peek) && close(peek))
  }

  const onKeyDown = e => {
    if (e.key !== "Escape") return
    const focused = peekOf(document.activeElement)

    all().forEach(peek => {
      if (!isOpen(peek)) return
      close(peek)
      if (peek.matches(":hover")) peek.dataset.dismissed = ""
    })

    if (focused) triggerOf(focused)?.focus()
  }

  root.addEventListener("pointerover", onPointerOver)
  root.addEventListener("pointerout", onPointerOut)
  root.addEventListener("focusin", onFocusIn)
  root.addEventListener("focusout", onFocusOut)
  document.addEventListener("click", onClick)
  document.addEventListener("keydown", onKeyDown)

  return () => {
    root.removeEventListener("pointerover", onPointerOver)
    root.removeEventListener("pointerout", onPointerOut)
    root.removeEventListener("focusin", onFocusIn)
    root.removeEventListener("focusout", onFocusOut)
    document.removeEventListener("click", onClick)
    document.removeEventListener("keydown", onKeyDown)
  }
}

// The change flow: the d20 visits each step; approval steps hold longer and
// stamp the founders' seal. Plays once when scrolled into view.
export const TeamFlow = {
  mounted() {
    this.steps = [...this.el.querySelectorAll("[data-flow-step]")]
    this.track = this.el.querySelector("[data-flow-track]")
    this.token = this.el.querySelector("[data-flow-token]")
    this.timers = []
    this.current = null
    this.mq = reducedMotion()

    this.onReplay = () => this.play()
    this.replayButton = this.el.querySelector("[data-flow-replay]")
    this.replayButton?.addEventListener("click", this.onReplay)

    this.onResize = () => this.place(this.current)
    window.addEventListener("resize", this.onResize)

    this.onChange = () => this.mq.matches && this.settle()
    this.mq.addEventListener("change", this.onChange)

    if (this.mq.matches || !("IntersectionObserver" in window)) return this.settle()

    this.observer = new IntersectionObserver(entries => {
      if (!entries.some(e => e.isIntersecting)) return
      this.observer.disconnect()
      this.play()
    }, {threshold: 0.3})
    this.observer.observe(this.el)
  },

  // Static diagram: every step lit, no token.
  settle() {
    this.clear()
    this.el.dataset.flow = "static"
    this.steps.forEach(s => { delete s.dataset.state; delete s.dataset.stamped })
  },

  play() {
    if (this.mq.matches) return this.settle()
    this.clear()
    this.el.dataset.flow = "playing"
    this.steps.forEach(s => { s.dataset.state = "idle"; delete s.dataset.stamped })

    let at = 250
    this.steps.forEach((step, i) => {
      this.later(at, () => {
        this.current = i
        this.place(i)
        step.dataset.state = "lit"
        if (step.dataset.approval) step.dataset.stamped = "true"
      })
      at += step.dataset.approval ? 1600 : 600
    })
    this.later(at, () => { this.el.dataset.flow = "done" })
  },

  place(i) {
    if (i == null || !this.token || !this.track) return
    const marker = this.steps[i]?.querySelector("[data-flow-marker]")
    if (!marker) return
    const box = this.track.getBoundingClientRect()
    const m = marker.getBoundingClientRect()
    const x = m.left - box.left + m.width / 2
    const y = m.top - box.top + m.height / 2
    this.token.style.transform = `translate(${x}px, ${y}px) translate(-50%, -50%) rotate(${i * 72}deg)`
  },

  later(ms, fun) { this.timers.push(setTimeout(fun, ms)) },

  clear() {
    this.timers.forEach(clearTimeout)
    this.timers = []
  },

  destroyed() {
    this.clear()
    this.observer?.disconnect()
    window.removeEventListener("resize", this.onResize)
    this.mq?.removeEventListener("change", this.onChange)
    this.replayButton?.removeEventListener("click", this.onReplay)
  },
}

// One turn, three lanes (TalesForgeWeb.TeamCallTypes): the player's line, the
// Jev card, the Elixir roll, the GM's prose and the parchment out to the
// player appear one after another (about 6 s). Plays once when scrolled into
// view, with a Replay button. Every [data-at] element is visible in the
// server's static diagram; only while playing are the ones not yet reached
// hidden (app.css, under data-motion="full").
const LANE_STEPS = [200, 1100, 2200, 3600, 5300]
const LANES_DONE = 6200

export const TeamLanes = {
  mounted() {
    this.timers = []
    this.mq = reducedMotion()
    this.parts = [...this.el.querySelectorAll("[data-at]")]

    this.onReplay = () => this.play()
    this.replayButton = this.el.querySelector("[data-lanes-replay]")
    this.replayButton?.addEventListener("click", this.onReplay)

    this.onChange = () => this.mq.matches && this.settle()
    this.mq.addEventListener("change", this.onChange)

    if (this.mq.matches || !("IntersectionObserver" in window)) return this.settle()

    this.observer = new IntersectionObserver(entries => {
      if (!entries.some(e => e.isIntersecting)) return
      this.observer.disconnect()
      this.play()
    }, {threshold: 0.3})
    this.observer.observe(this.el)
  },

  // Static, numbered diagram: everything shown.
  settle() {
    this.clear()
    this.el.dataset.lanes = "static"
    this.parts.forEach(p => { delete p.dataset.shown })
  },

  play() {
    if (this.mq.matches) return this.settle()
    this.clear()
    this.parts.forEach(p => { delete p.dataset.shown })
    this.el.dataset.lanes = "playing"

    LANE_STEPS.forEach((at, i) => {
      this.later(at, () => {
        this.parts.forEach(p => { if (p.dataset.at === String(i + 1)) p.dataset.shown = "true" })
      })
    })
    this.later(LANES_DONE, () => { this.el.dataset.lanes = "done" })
  },

  later(ms, fun) { this.timers.push(setTimeout(fun, ms)) },

  clear() {
    this.timers.forEach(clearTimeout)
    this.timers = []
  },

  destroyed() {
    this.clear()
    this.observer?.disconnect()
    this.mq?.removeEventListener("change", this.onChange)
    this.replayButton?.removeEventListener("click", this.onReplay)
  },
}

// The shared board's mock (TalesForgeWeb.TeamBoard, presentation section 6):
// one card is dropped into Ideas, then moves column by column to Done (about
// 8 s), once when scrolled into view, with a Replay button. The server renders
// the static board (one card in every column, labelled); only while playing
// are the steps not yet reached hidden, and a card that has moved on fades
// out (data-gone), left as a faint trail once the story is done.
const BOARD_STEPS = [200, 1500, 2900, 4500, 6000, 7200]
const BOARD_DONE = 8200

export const TeamBoard = {
  mounted() {
    this.timers = []
    this.mq = reducedMotion()
    this.parts = [...this.el.querySelectorAll("[data-at]")]

    this.onReplay = () => this.play()
    this.replayButton = this.el.querySelector("[data-board-replay]")
    this.replayButton?.addEventListener("click", this.onReplay)

    this.onChange = () => this.mq.matches && this.settle()
    this.mq.addEventListener("change", this.onChange)

    if (this.mq.matches || !("IntersectionObserver" in window)) return this.settle()

    this.observer = new IntersectionObserver(entries => {
      if (!entries.some(e => e.isIntersecting)) return
      this.observer.disconnect()
      this.play()
    }, {threshold: 0.3})
    this.observer.observe(this.el)
  },

  // Static board: one card in each column, everything shown.
  settle() {
    this.clear()
    this.el.dataset.board = "static"
    this.parts.forEach(p => { delete p.dataset.shown; delete p.dataset.gone })
  },

  play() {
    if (this.mq.matches) return this.settle()
    this.clear()
    this.parts.forEach(p => { delete p.dataset.shown; delete p.dataset.gone })
    this.el.dataset.board = "playing"

    BOARD_STEPS.forEach((at, i) => {
      const step = i + 1
      this.later(at, () => {
        this.parts.forEach(p => {
          if (p.dataset.at === String(step)) p.dataset.shown = "true"
          if (p.dataset.until && Number(p.dataset.until) < step) p.dataset.gone = "true"
        })
      })
    })
    this.later(BOARD_DONE, () => { this.el.dataset.board = "done" })
  },

  later(ms, fun) { this.timers.push(setTimeout(fun, ms)) },

  clear() {
    this.timers.forEach(clearTimeout)
    this.timers = []
  },

  destroyed() {
    this.clear()
    this.observer?.disconnect()
    this.mq?.removeEventListener("change", this.onChange)
    this.replayButton?.removeEventListener("click", this.onReplay)
  },
}

// Old links to the presentation's sections pointed at /team#section. The
// server never sees the fragment, so on /team this hook checks it: when it
// is one of the presentation's anchors (data-anchors, from
// TeamPresentationLive.anchors/0), the URL is replaced with
// /team/presentation#section, so Back skips the landing page. Anything else
// (the landing page's own anchors, no fragment) stays put.
export const presentationTarget = (hash, anchors, target) => {
  const anchor = decodeURIComponent((hash || "").replace(/^#/, ""))
  return anchor && anchors.includes(anchor) ? `${target}#${anchor}` : null
}

export const TeamAnchorRedirect = {
  mounted() {
    this.anchors = JSON.parse(this.el.dataset.anchors || "[]")
    this.onHash = () => this.check()
    window.addEventListener("hashchange", this.onHash)
    this.check()
  },

  check() {
    const to = presentationTarget(window.location.hash, this.anchors, this.el.dataset.target)
    if (to) window.location.replace(to)
  },

  destroyed() {
    window.removeEventListener("hashchange", this.onHash)
  },
}
