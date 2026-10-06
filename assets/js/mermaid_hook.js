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
// Use on an element whose id changes with its content and that has
// phx-update="ignore", so LiveView swaps the whole element (and calls
// mounted) when another doc is selected instead of patching away the SVGs.

let mermaidPromise = null
let renderSeq = 0

const FIT_RATIO = 1.5

const PAPER = {
  bg: "#f4ead5",
  panel: "#faf6ec",
  ink: "#3d2f24",
  muted: "#6b5c4f",
  rule: "#d4c4a8",
  accent: "#9a3412",
  margin: "#ebe3d0",
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
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: "base",
        fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', sans-serif",
        themeVariables: {
          background: PAPER.panel,
          fontSize: "14px",
          primaryColor: PAPER.panel,
          primaryTextColor: PAPER.ink,
          primaryBorderColor: PAPER.accent,
          secondaryColor: PAPER.margin,
          secondaryTextColor: PAPER.ink,
          secondaryBorderColor: PAPER.rule,
          tertiaryColor: PAPER.bg,
          tertiaryTextColor: PAPER.ink,
          tertiaryBorderColor: PAPER.rule,
          lineColor: PAPER.muted,
          textColor: PAPER.ink,
          clusterBkg: PAPER.bg,
          clusterBorder: PAPER.rule,
          titleColor: PAPER.ink,
          edgeLabelBackground: PAPER.panel,
          noteBkgColor: PAPER.margin,
          noteBorderColor: PAPER.rule,
          noteTextColor: PAPER.ink,
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

export const Mermaid = {
  mounted() {
    renderDiagrams(this.el)
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
  },
  updated() { renderDiagrams(this.el) },
  destroyed() { this.resizeObserver && this.resizeObserver.disconnect() },
}
