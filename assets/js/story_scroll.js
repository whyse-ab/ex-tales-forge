// StoryScroll keeps the newest story text visible on the play page.
//
// - When the page opens, the story box scrolls to the end.
// - When new text arrives (a GM reply, the player's action, or a "GM is
//   thinking" line) and the player is at the end, the box scrolls to the end.
// - When new text arrives and the player scrolled up to read older text, the
//   box stays where it is and the "New text below" button shows. The button
//   scrolls to the end. The button goes away when the player is at the end.
// - When the box changes size (a window resize, a phone rotation, or the
//   on-screen keyboard), a player who was at the end stays at the end.
//
// The button is in a phx-update="ignore" wrapper (id "story-new-text-region")
// so LiveView patches keep the visibility that this hook sets.
const NEAR_END_PX = 80

export const StoryScroll = {
  mounted() {
    this.follow = true
    this.button = document.getElementById("story-new-text")
    this.toEnd()

    this.onScroll = () => {
      this.follow = this.gap() <= NEAR_END_PX
      if (this.follow) this.setButton(false)
    }
    this.el.addEventListener("scroll", this.onScroll, {passive: true})

    this.onButton = () => {
      this.follow = true
      this.setButton(false)
      this.toEnd("smooth")
    }
    if (this.button) this.button.addEventListener("click", this.onButton)

    this.observer = new MutationObserver(() => {
      if (this.follow) this.toEnd()
      else this.setButton(true)
    })
    this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})

    // The scroll listener does not run when only the box height changes, so
    // `follow` still holds the state from before the resize.
    this.onResize = () => { if (this.follow) this.toEnd() }
    if (window.ResizeObserver) {
      this.resizer = new ResizeObserver(this.onResize)
      this.resizer.observe(this.el)
    }
    window.addEventListener("resize", this.onResize)
    if (window.visualViewport) window.visualViewport.addEventListener("resize", this.onResize)
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
    if (this.resizer) this.resizer.disconnect()
    window.removeEventListener("resize", this.onResize)
    if (window.visualViewport) window.visualViewport.removeEventListener("resize", this.onResize)
    if (this.button) this.button.removeEventListener("click", this.onButton)
  },
  gap() {
    return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
  },
  setButton(show) {
    if (this.button) this.button.hidden = !show
  },
  toEnd(behavior = "auto") {
    requestAnimationFrame(() => {
      this.el.scrollTo({top: this.el.scrollHeight, behavior})
    })
  },
}
