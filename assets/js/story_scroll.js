// StoryScroll keeps the newest story text visible on the play page.
// When the page opens, the story box scrolls to the end. When new text
// arrives (a GM reply, the player's action, or a "GM is thinking" line),
// the box scrolls to the end again. If the player scrolled up to read
// older text, the box stays where it is until the player scrolls back
// near the end.
const NEAR_END_PX = 80

export const StoryScroll = {
  mounted() {
    this.follow = true
    this.toEnd()
    this.el.addEventListener("scroll", () => {
      const gap = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
      this.follow = gap <= NEAR_END_PX
    }, {passive: true})
    this.observer = new MutationObserver(() => { if (this.follow) this.toEnd() })
    this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
  },
  destroyed() {
    if (this.observer) this.observer.disconnect()
  },
  toEnd() {
    requestAnimationFrame(() => { this.el.scrollTop = this.el.scrollHeight })
  },
}
