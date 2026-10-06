// Renders ```mermaid fenced blocks (MDEx: <pre><code class="language-mermaid">,
// with the source HTML-escaped so labels like `<br/>` survive as text) as
// diagrams. Mermaid is ~5 MB, so it is vendored in priv/static/vendor and only
// loaded the first time a page actually contains a diagram.
//
// Diagrams render at natural size. One that is only a little wider than its
// box (natural width <= FIT_RATIO x available width) gets .mermaid-fit and is
// scaled down to fit; anything wider keeps its size and scrolls sideways, so
// the text never shrinks below ~2/3 of its natural size.
//
// Colours come from the page's --paper-* CSS variables (assets/css/app.css),
// read at render time, so diagrams match the light or dark admin palette.
// When the theme toggle flips data-theme on <html>, diagrams are re-rendered.
//
// Use on an element whose id changes with its content and that has
// phx-update="ignore", so LiveView swaps the whole element (and calls
// mounted) when another doc is selected instead of patching away the SVGs.

let mermaidPromise = null
let renderSeq = 0

const FIT_RATIO = 1.5

// Fallback when the CSS variables are missing (light paper palette).
const PAPER = {
  bg: "#f4ead5",
  panel: "#faf6ec",
  ink: "#3d2f24",
  muted: "#6b5c4f",
  rule: "#d4c4a8",
  accent: "#9a3412",
  margin: "#ebe3d0",
}

function currentPalette() {
  const style = getComputedStyle(document.documentElement)
  const palette = {}
  for (const [name, fallback] of Object.entries(PAPER)) {
    palette[name] = style.getPropertyValue(`--paper-${name}`).trim() || fallback
  }
  palette.dark = document.documentElement.getAttribute("data-theme") === "dark" &&
    style.getPropertyValue("color-scheme").trim() === "dark"
  return palette
}

// Mermaid's config is global, so set it (with the current palette) right
// before each batch of renders.
function configure(mermaid) {
  const p = currentPalette()
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: "base",
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif",
    themeVariables: {
      darkMode: p.dark,
      background: p.panel,
      fontSize: "14px",
      mainBkg: p.panel,
      nodeBorder: p.accent,
      nodeTextColor: p.ink,
      primaryColor: p.panel,
      primaryTextColor: p.ink,
      primaryBorderColor: p.accent,
      secondaryColor: p.margin,
      secondaryTextColor: p.ink,
      secondaryBorderColor: p.rule,
      tertiaryColor: p.bg,
      tertiaryTextColor: p.ink,
      tertiaryBorderColor: p.rule,
      lineColor: p.muted,
      textColor: p.ink,
      clusterBkg: p.bg,
      clusterBorder: p.rule,
      titleColor: p.ink,
      edgeLabelBackground: p.panel,
      noteBkgColor: p.margin,
      noteBorderColor: p.rule,
      noteTextColor: p.ink,
      actorBkg: p.panel,
      actorBorder: p.accent,
      actorTextColor: p.ink,
      actorLineColor: p.muted,
      signalColor: p.muted,
      signalTextColor: p.ink,
      labelBoxBkgColor: p.margin,
      labelBoxBorderColor: p.rule,
      labelTextColor: p.ink,
      loopTextColor: p.ink,
    },
    // Keep natural size; fitDiagram() decides whether to scale down or
    // let the wrapper scroll sideways.
    flowchart: {useMaxWidth: false, htmlLabels: true},
    sequence: {useMaxWidth: false},
    gantt: {useMaxWidth: false},
    class: {useMaxWidth: false},
    state: {useMaxWidth: false},
    er: {useMaxWidth: false},
    journey: {useMaxWidth: false},
    timeline: {useMaxWidth: false},
    mindmap: {useMaxWidth: false},
  })
}

function loadMermaid() {
  if (window.mermaid) return Promise.resolve(window.mermaid)
  if (mermaidPromise) return mermaidPromise

  const meta = document.querySelector("meta[name='mermaid-src']")
  const src = meta && meta.getAttribute("content")
  if (!src) return Promise.reject(new Error("mermaid-src meta tag missing"))

  mermaidPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = src
    script.async = true
    script.onload = () => {
      const mermaid = window.mermaid
      if (!mermaid) return reject(new Error("mermaid failed to initialise"))
      resolve(mermaid)
    }
    script.onerror = () => {
      mermaidPromise = null
      reject(new Error(`could not load ${src}`))
    }
    document.head.appendChild(script)
  })

  return mermaidPromise
}

// Natural (unscaled) width of a rendered diagram, from its viewBox.
function naturalWidth(svg) {
  const vb = svg.viewBox && svg.viewBox.baseVal
  if (vb && vb.width) return vb.width
  return parseFloat(svg.getAttribute("width")) || 0
}

function fitDiagram(figure) {
  const svg = figure.querySelector("svg")
  if (!svg) return
  const style = getComputedStyle(figure)
  const available =
    figure.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)
  const natural = naturalWidth(svg)
  if (available <= 0 || natural <= 0) return
  figure.classList.toggle("mermaid-fit", natural <= available * FIT_RATIO)
}

function fitDiagrams(root) {
  root.querySelectorAll(".mermaid-diagram").forEach(fitDiagram)
}

async function renderDiagrams(root) {
  const blocks = Array.from(
    root.querySelectorAll("pre > code.mermaid, pre > code.language-mermaid")
  ).filter(code => !code.parentElement.dataset.mermaid)
  if (blocks.length === 0) return

  let mermaid
  try {
    mermaid = await loadMermaid()
  } catch (err) {
    console.warn("[mermaid]", err)
    return // leave the code blocks as they are
  }

  configure(mermaid)

  for (const code of blocks) {
    const pre = code.parentElement
    if (!pre.isConnected || pre.dataset.mermaid) continue
    pre.dataset.mermaid = "pending"
    const source = code.textContent
    const id = `mermaid-svg-${++renderSeq}`

    try {
      await mermaid.parse(source)
      const {svg, bindFunctions} = await mermaid.render(id, source)

      const figure = document.createElement("div")
      figure.className = "mermaid-diagram"
      figure.setAttribute("role", "img")
      figure.innerHTML = svg
      bindFunctions && bindFunctions(figure)

      pre.dataset.mermaid = "rendered"
      pre.hidden = true
      pre.before(figure)
      fitDiagram(figure)
    } catch (err) {
      // Bad syntax: keep the source visible and say why.
      pre.dataset.mermaid = "error"
      const note = document.createElement("p")
      note.className = "mermaid-error"
      note.textContent = `Diagram could not be rendered: ${(err && err.message || err || "").toString().split("\n")[0]}`
      pre.after(note)
      // mermaid.render leaves its scratch element behind on failure
      document.getElementById(`d${id}`)?.remove()
    }
  }
}

// Drop rendered diagrams (and error notes) and show the sources again, so
// renderDiagrams() draws them afresh, e.g. in the new theme's colours.
function resetDiagrams(root) {
  root.querySelectorAll(".mermaid-diagram, .mermaid-error").forEach(el => el.remove())
  root.querySelectorAll("pre[data-mermaid]").forEach(pre => {
    delete pre.dataset.mermaid
    pre.hidden = false
  })
}

export const Mermaid = {
  mounted() {
    // Renders run one after another (theme flips can arrive mid-render).
    this.queue = Promise.resolve()
    this.render = () => { this.queue = this.queue.then(() => renderDiagrams(this.el)) }
    this.render()
    // Re-fit on rotation/resize; only width changes matter, and at most once
    // per frame.
    let lastWidth = this.el.clientWidth
    let frame = null
    this.resizeObserver = new ResizeObserver(() => {
      const width = this.el.clientWidth
      if (width === lastWidth || frame) return
      lastWidth = width
      frame = requestAnimationFrame(() => {
        frame = null
        fitDiagrams(this.el)
      })
    })
    this.resizeObserver.observe(this.el)
    // Theme toggle (or OS change in "system" mode) flips data-theme on <html>.
    this.themeObserver = new MutationObserver(() => {
      this.queue = this.queue.then(() => resetDiagrams(this.el))
      this.render()
    })
    this.themeObserver.observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]})
  },
  updated() { this.render() },
  destroyed() {
    this.resizeObserver && this.resizeObserver.disconnect()
    this.themeObserver && this.themeObserver.disconnect()
  },
}
