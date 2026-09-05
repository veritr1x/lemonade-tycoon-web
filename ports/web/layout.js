// All rectangles use CSS pixels for display and original game pixels for source.
// Painting and pointer input share this plan, including keyboard focus crops.
const rect = (x, y, w, h) => ({ x, y, w, h });
export function fit(source, space) {
  const scale = Math.max(0, Math.min(space.w / source.w, space.h / source.h));
  const w = source.w * scale,
    h = source.h * scale;
  return rect(space.x + (space.w - w) / 2, space.y + (space.h - h) / 2, w, h);
}
export function textCrop(field) {
  const w = Math.min(640, Math.max(320, field.w + 32)),
    h = Math.min(480, Math.max(150, field.h + 64));
  return rect(
    Math.max(0, Math.min(640 - w, field.x + field.w / 2 - w / 2)),
    Math.max(0, Math.min(480 - h, field.y + field.h / 2 - h / 2)),
    w,
    h,
  );
}
// split is the fraction of the available axis reserved for the controls.
// Both painting and the draggable separator consume this geometry.
export function splitRatio(value, wide = false) {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.max(0.25, Math.min(0.78, value))
    : wide
      ? 0.48
      : 0.52;
}
export function adaptiveLayout(width, height, split) {
  const wide = width > height,
    gap = Math.min(16, width, height),
    span = Math.max(0, (wide ? width : height) - gap),
    minimum = Math.min(112, span / 2),
    ratio = splitRatio(split, wide),
    controlsLength = Math.min(span - minimum, Math.max(minimum, span * ratio)),
    worldLength = span - controlsLength;
  return {
    wide,
    span,
    ratio,
    world: wide
      ? rect(0, 0, worldLength, height)
      : rect(0, 0, width, worldLength),
    divider: wide
      ? rect(worldLength, 0, gap, height)
      : rect(0, worldLength, width, gap),
    controls: wide
      ? rect(worldLength + gap, 0, controlsLength, height)
      : rect(0, worldLength + gap, width, controlsLength),
  };
}
export function plan(
  width,
  height,
  {
    mode = "fill",
    portrait = false,
    field = null,
    keyboardOpen = false,
    split,
  } = {},
) {
  const full = rect(0, 0, 640, 480),
    space = rect(0, 0, width, height);
  if (mode === "adaptive") {
    const weather = rect(327, 35, 306, 76),
      street = rect(331, 124, 302, 242),
      controls = rect(0, 0, 320, 480),
      areas = adaptiveLayout(width, height, split),
      world = areas.world,
      gap = Math.min(8, world.h),
      heading = Math.min(world.h * 0.28, (world.w * 76) / 306);
    return [
      { source: weather, display: fit(weather, rect(0, 0, world.w, heading)) },
      {
        source: street,
        display: fit(
          street,
          rect(0, heading + gap, world.w, Math.max(0, world.h - heading - gap)),
        ),
      },
      // Uniform scaling preserves every original button at every divider position.
      { source: controls, display: fit(controls, areas.controls) },
    ];
  }
  if (mode === "original" || !portrait)
    return [
      { source: full, display: mode === "fill" ? space : fit(full, space) },
    ];
  const gap = Math.min(12, Math.max(0, height)),
    h = Math.max(0, (height - gap) / 2);
  return [false, true].map((bottom) => {
    let source = rect(bottom ? 0 : 320, 0, 320, 480);
    if (field && keyboardOpen && field.x + field.w / 2 < 320 === bottom)
      source = textCrop(field);
    const area = rect(0, bottom ? h + gap : 0, width, h);
    return { source, display: mode === "fill" ? area : fit(source, area) };
  });
}
export function contains(rect, p) {
  return (
    p.x >= rect.x &&
    p.y >= rect.y &&
    p.x < rect.x + rect.w &&
    p.y < rect.y + rect.h
  );
}
export function mapPoint(p, { source: s, display: d }) {
  return d.w > 0 && d.h > 0
    ? { x: s.x + ((p.x - d.x) * s.w) / d.w, y: s.y + ((p.y - d.y) * s.h) / d.h }
    : { x: -1, y: -1 };
}

export class GameSurface {
  constructor(canvas, cancel) {
    this.canvas = canvas;
    this.cancel = cancel;
    this.source = document.createElement("canvas");
    this.source.width = 640;
    this.source.height = 480;
    this.context = this.source.getContext("2d", { alpha: false });
    this.display = canvas.getContext("2d", { alpha: false });
    this.panes = [];
  }
  resize(width, height, options) {
    const panes = plan(width, height, options);
    if (JSON.stringify(panes) !== JSON.stringify(this.panes)) this.cancel();
    this.panes = panes;
    const ratio = Math.min(3, devicePixelRatio || 1);
    this.canvas.style.width = `${width}px`;
    this.canvas.style.height = `${height}px`;
    const w = Math.max(1, Math.round(width * ratio)),
      h = Math.max(1, Math.round(height * ratio));
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    this.display.setTransform(ratio, 0, 0, ratio, 0, 0);
    this.display.imageSmoothingEnabled = false;
    this.paint();
  }
  frame(pixels, w, h) {
    this.context.putImageData(new ImageData(pixels, w, h), 0, 0);
    this.paint();
  }
  paint() {
    const ctx = this.display;
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    for (const { source: s, display: d } of this.panes)
      if (d.w && d.h)
        ctx.drawImage(this.source, s.x, s.y, s.w, s.h, d.x, d.y, d.w, d.h);
  }
  local(event) {
    const box = this.canvas.getBoundingClientRect();
    return { x: event.clientX - box.left, y: event.clientY - box.top };
  }
  point(event, held = false) {
    const local = this.local(event);
    const pane = held
      ? this.gesture
      : this.panes.find((p) => contains(p.display, local));
    return pane ? mapPoint(local, pane) : null;
  }
  begin(event) {
    this.gesture = this.panes.find((p) =>
      contains(p.display, this.local(event)),
    );
  }
  fieldRect(field) {
    const pane = this.panes.find((p) =>
      contains(p.source, {
        x: field.x + field.w / 2,
        y: field.y + field.h / 2,
      }),
    );
    if (!pane) return null;
    const { source: s, display: d } = pane;
    return rect(
      d.x + ((field.x - s.x) * d.w) / s.w,
      d.y + ((field.y - s.y) * d.h) / s.h,
      (field.w * d.w) / s.w,
      (field.h * d.h) / s.h,
    );
  }
}
