import { adaptiveLayout, splitRatio } from "./layout.js";
import { readPreference, writePreference } from "./preferences.js";

// The separator only changes presentation. It releases any held game button
// before moving the same rectangles that canvas painting and input use.
export class AdaptiveSplitter {
  constructor(element, screen, change, cancelGame) {
    this.element = element;
    this.screen = screen;
    this.change = change;
    this.cancelGame = cancelGame;
    this.ratios = [
      splitRatio(readPreference("adaptivePortraitSplit", null)),
      splitRatio(readPreference("adaptiveWideSplit", null), true),
    ];
    this.drag = null;
    element.addEventListener("pointerdown", (event) => {
      if (element.hidden || event.button !== 0 || this.drag) return;
      event.preventDefault();
      this.cancelGame();
      const area = this.geometry();
      this.drag = {
        id: event.pointerId,
        wide: area.wide,
        width: screen.clientWidth,
        height: screen.clientHeight,
        start: area.wide ? event.clientX : event.clientY,
        length: area.wide ? area.controls.w : area.controls.h,
        span: area.span,
      };
      element.setPointerCapture(event.pointerId);
      element.focus({ preventScroll: true });
      element.classList.add("dragging");
    });
    element.addEventListener("pointermove", (event) => this.move(event));
    element.addEventListener("pointerup", (event) => {
      if (this.drag?.id !== event.pointerId) return;
      this.move(event);
      this.cancel();
    });
    for (const event of ["pointercancel", "lostpointercapture"])
      element.addEventListener(event, () => this.cancel());
    element.addEventListener("dblclick", () => this.reset());
    element.addEventListener("keydown", (event) => {
      const wide = this.geometry().wide;
      const increase = wide ? "ArrowLeft" : "ArrowUp";
      const decrease = wide ? "ArrowRight" : "ArrowDown";
      let next;
      if (event.key === increase) next = this.value(wide) + 0.025;
      else if (event.key === decrease) next = this.value(wide) - 0.025;
      else if (event.key === "Home") next = 0.25;
      else if (event.key === "End") next = 0.78;
      else if (event.key === "Enter") next = splitRatio(null, wide);
      else return;
      event.preventDefault();
      this.cancelGame();
      this.set(next, wide, true);
    });
  }
  value(wide) {
    return this.ratios[wide ? 1 : 0];
  }
  geometry() {
    const { clientWidth: width, clientHeight: height } = this.screen;
    return adaptiveLayout(width, height, this.value(width > height));
  }
  set(ratio, wide, save = false) {
    this.ratios[wide ? 1 : 0] = splitRatio(ratio, wide);
    if (save) this.save(wide);
    this.change();
  }
  save(wide) {
    writePreference(
      wide ? "adaptiveWideSplit" : "adaptivePortraitSplit",
      this.value(wide),
    );
  }
  move(event) {
    const drag = this.drag;
    if (!drag || event.pointerId !== drag.id || !drag.span) return;
    event.preventDefault();
    const delta = (drag.wide ? event.clientX : event.clientY) - drag.start;
    this.set((drag.length - delta) / drag.span, drag.wide);
  }
  cancel() {
    if (!this.drag) return;
    const { id, wide } = this.drag;
    this.drag = null;
    this.save(wide);
    this.element.classList.remove("dragging");
    if (this.element.hasPointerCapture(id))
      this.element.releasePointerCapture(id);
  }
  reset() {
    this.cancel();
    this.cancelGame();
    const wide = this.geometry().wide;
    this.set(null, wide, true);
  }
  update(enabled) {
    const element = this.element,
      area = this.geometry(),
      d = area.divider;
    if (
      !enabled ||
      (this.drag &&
        (this.drag.width !== this.screen.clientWidth ||
          this.drag.height !== this.screen.clientHeight))
    )
      this.cancel();
    element.hidden = !enabled;
    if (!enabled) return;
    element.classList.toggle("vertical", area.wide);
    // A 44-pixel hit area surrounds the small visible bar. It stays between
    // the panes and never changes the original source crops.
    Object.assign(element.style, {
      left: `${area.wide ? d.x + d.w / 2 - 22 : d.x}px`,
      top: `${area.wide ? d.y : d.y + d.h / 2 - 22}px`,
      width: `${area.wide ? 44 : d.w}px`,
      height: `${area.wide ? d.h : 44}px`,
    });
    const percent = Math.round(
      ((area.wide ? area.controls.w : area.controls.h) / (area.span || 1)) *
        100,
    );
    element.setAttribute(
      "aria-orientation",
      area.wide ? "vertical" : "horizontal",
    );
    element.setAttribute("aria-valuenow", percent);
    element.setAttribute("aria-valuetext", `${percent}% controls`);
  }
}
