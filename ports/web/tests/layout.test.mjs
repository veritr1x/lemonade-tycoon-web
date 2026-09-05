import assert from "node:assert/strict";
import {
  plan,
  mapPoint,
  contains,
  adaptiveLayout,
  splitRatio,
} from "../layout.js";
for (const [w, h, portrait] of [
  [390, 760, true],
  [844, 340, false],
  [768, 960, true],
]) {
  for (const mode of ["fill", "fit", "original"]) {
    const panes = plan(w, h, { mode, portrait });
    for (const pane of panes) {
      const { source: s, display: d } = pane;
      const p = mapPoint({ x: d.x + d.w * 0.37, y: d.y + d.h * 0.61 }, pane);
      assert(Math.abs(p.x - (s.x + s.w * 0.37)) < 1e-9);
      assert(Math.abs(p.y - (s.y + s.h * 0.61)) < 1e-9);
      assert(
        d.x >= 0 &&
          d.y >= 0 &&
          d.x + d.w <= w + 0.001 &&
          d.y + d.h <= h + 0.001,
      );
      if (mode !== "fill") assert(Math.abs(d.w / d.h - s.w / s.h) < 1e-9);
    }
    if (portrait && mode !== "original") assert.equal(panes[0].source.x, 320);
  }
}
const field = { x: 50, y: 280, w: 150, h: 20 };
const panes = plan(390, 380, { portrait: true, field, keyboardOpen: true });
assert(contains(panes[1].source, { x: 125, y: 290 }));
assert(panes[1].source.h < 480);
assert(!contains(panes[0].display, { x: 20, y: 190 })); // Gap never sends a game click.
console.log(
  "PASS: web portrait/widescreen, fit/fill, keyboard crops, and inverse pointer mapping",
);
for (const [w, h] of [
  [300, 400],
  [390, 760],
  [390, 844],
  [320, 960],
  [844, 390],
  [768, 1024],
  [1366, 768],
]) {
  for (const split of [undefined, 0.25, 0.52, 0.78]) {
    const panes = plan(w, h, { mode: "adaptive", split });
    const areas = adaptiveLayout(w, h, split);
    assert.equal(panes.length, 3);
    const controls = panes[2];
    assert.deepEqual(controls.source, { x: 0, y: 0, w: 320, h: 480 });
    if (split === undefined) assert.equal(areas.ratio, w > h ? 0.48 : 0.52);
    // The visible separator and the source-mapped panes never overlap.
    const center = {
      x: areas.divider.x + areas.divider.w / 2,
      y: areas.divider.y + areas.divider.h / 2,
    };
    assert(!panes.some((p) => contains(p.display, center)));
    assert(areas.world.w >= 112 && areas.world.h >= 112);
    for (const [x, y] of [
      [257, 80],
      [294, 80],
      [272, 468],
    ]) {
      const d = controls.display;
      const click = { x: d.x + (x * d.w) / 320, y: d.y + (y * d.h) / 480 };
      assert(contains(d, click));
      const mapped = mapPoint(click, controls);
      assert(Math.abs(mapped.x - x) < 1e-9 && Math.abs(mapped.y - y) < 1e-9);
    }
    for (const p of panes) {
      assert(
        p.display.x >= -0.001 &&
          p.display.y >= -0.001 &&
          p.display.x + p.display.w <= w + 0.001 &&
          p.display.y + p.display.h <= h + 0.001,
      );
      assert(
        Math.abs(p.source.w / p.source.h - p.display.w / p.display.h) < 1e-9,
      );
    }
  }
}
assert.equal(splitRatio(null), 0.52);
assert.equal(splitRatio(NaN, true), 0.48);
assert.equal(splitRatio(".7"), 0.52);
assert.equal(splitRatio(-1), 0.25);
assert.equal(splitRatio(2), 0.78);
assert.equal(adaptiveLayout(100, 100, 0.78).controls.h, 42);
console.log(
  "PASS: adjustable Adaptive panes, defaults, bounds, separator gap and original buttons",
);
