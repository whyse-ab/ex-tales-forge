// Animations of the founders' page (/team, TalesForgeWeb.TeamLive).
//
// Everything here is decoration: the server renders the full, static page
// (every flow step lit, every bar at its size), and nothing is hidden until
// this code has decided motion is allowed. With prefers-reduced-motion the
// page root gets data-motion="reduce" and nothing moves; otherwise
// data-motion="full", sections fade in as they scroll into view, their bars
// grow (CSS, app.css "Founders' page"), and the d20 rolls through the change
// flow once, with a Replay button.

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)")

// Root hook: sets data-motion and reveals [data-reveal] sections in view.
export const TeamPage = {
  mounted() {
    this.mq = reducedMotion()
    this.onChange = () => this.apply()
    this.mq.addEventListener("change", this.onChange)
    this.apply()
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
  },
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
