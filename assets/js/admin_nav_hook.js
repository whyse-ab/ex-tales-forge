// Admin section nav. On phones it is one horizontally scrolling row: scroll
// the active tab fully into view (so e.g. "Playtest runs" is never cut off at
// the edge) and mark which edges have more tabs so CSS can fade them as a
// "there's more" hint. On desktop the nav is a vertical list and nothing
// overflows, so this is a no-op.

function updateEdges(nav) {
  const max = nav.scrollWidth - nav.clientWidth
  nav.dataset.moreStart = nav.scrollLeft > 1 ? "true" : "false"
  nav.dataset.moreEnd = nav.scrollLeft < max - 1 ? "true" : "false"
}

// Centre the active tab in the row (the browser clamps at either end), so it
// is fully visible and clear of the edge fades.
function revealActive(nav) {
  const active = nav.querySelector("[aria-current='page']")
  if (!active || nav.scrollWidth <= nav.clientWidth) return
  const left = active.getBoundingClientRect().left - nav.getBoundingClientRect().left + nav.scrollLeft
  nav.scrollLeft = left - (nav.clientWidth - active.offsetWidth) / 2
}

export const AdminNav = {
  mounted() {
    this.onScroll = () => updateEdges(this.el)
    this.el.addEventListener("scroll", this.onScroll, {passive: true})
    this.resizeObserver = new ResizeObserver(() => updateEdges(this.el))
    this.resizeObserver.observe(this.el)
    revealActive(this.el)
    updateEdges(this.el)
  },
  updated() {
    revealActive(this.el)
    updateEdges(this.el)
  },
  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    this.resizeObserver && this.resizeObserver.disconnect()
  },
}
