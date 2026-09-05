import createLemonade from "./lemonade.js";
const $ = (id) => document.getElementById(id),
  canvas = $("game"),
  context = canvas.getContext("2d", { alpha: false });
const keyboard = $("keyboard"),
  cover = $("cover"),
  status = $("status"),
  play = $("play");
let game,
  running = false,
  active = true,
  field = null,
  pointer = null,
  consume = false,
  audio = null,
  nextAudio = 0,
  muted = false,
  frames = 0;
// Track scheduled audio so pause, mute, and quit can stop every queued sample.
const sources = new Set();
function stopAudio() {
  for (const source of sources) {
    try {
      source.stop();
    } catch {}
  }
  sources.clear();
  nextAudio = 0;
}
function ensureAudio() {
  if (!audio) audio = new AudioContext();
  if (!muted && active) audio.resume().catch(() => {});
}
// Keep a short Web Audio queue: enough to absorb rendering jitter without laggy effects.
function pumpAudio() {
  if (!audio || audio.state !== "running" || muted || !running) return;
  if (nextAudio < audio.currentTime) nextAudio = audio.currentTime + 0.025;
  for (let i = 0; i < 4 && nextAudio < audio.currentTime + 0.12; i++)
    game._lemon_web_audio(2048);
}
// The game always draws 640×480. CSS scales it; input coordinates use the inverse scale.
// visualViewport shrinks when a mobile software keyboard occupies the screen.
function layout() {
  const height = window.visualViewport?.height || innerHeight;
  const stageHeight = Math.max(
    100,
    height - (document.fullscreenElement ? 0 : 88),
  );
  $("stage").style.height = `${stageHeight}px`;
  const width = Math.min($("stage").clientWidth, (stageHeight * 4) / 3);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${(width * 3) / 4}px`;
  if (!field) return;
  const box = canvas.getBoundingClientRect(),
    stage = $("stage").getBoundingClientRect(),
    scale = box.width / 640;
  Object.assign(keyboard.style, {
    left: `${box.left - stage.left + field.x * scale}px`,
    top: `${box.top - stage.top + field.y * scale}px`,
    width: `${field.w * scale}px`,
    height: `${field.h * scale}px`,
  });
}
// Each animation frame gives the translated runtime a bounded slice of main-thread time.
function step() {
  try {
    if (running && active) {
      game._lemon_web_step();
      pumpAudio();
    }
  } catch (error) {
    fail(error);
  }
  requestAnimationFrame(step);
}
function fail(error) {
  console.error(error);
  running = false;
  stopAudio();
  cover.hidden = false;
  status.textContent =
    "The game could not continue. Reload the page to try again.";
  play.disabled = true;
}
// The factory loads the Wasm module and packaged assets; these callbacks are its host API.
try {
  game = await createLemonade({
    printErr: (line) => console.debug(line),
    onAbort: fail,
    onGameFrame(pixels, w, h) {
      context.putImageData(new ImageData(pixels, w, h), 0, 0);
      frames++;
      canvas.dataset.frames = frames;
      if (running) cover.hidden = true;
    },
    onGameKeyboard(visible, x, y, w, h) {
      field = visible ? { x, y, w, h } : null;
      keyboard.hidden = !visible;
      if (visible) {
        layout();
        keyboard.value = "";
        keyboard.focus({ preventScroll: true });
      } else keyboard.blur();
    },
    onGameURL(url) {
      const link = $("website");
      link.href = url;
      link.hidden = false;
      if (navigator.userActivation?.isActive)
        window.open(url, "_blank", "noopener");
      return 1;
    },
    onGameStopped(failed) {
      running = false;
      stopAudio();
      keyboard.blur();
      cover.hidden = false;
      status.textContent = failed
        ? "The game stopped unexpectedly."
        : "Game closed.";
      play.textContent = "Play again";
      play.disabled = false;
      syncSaves();
    },
    onGameAudioStop: stopAudio,
    onGameAudio(left, right) {
      if (!audio || audio.state !== "running" || muted) return;
      const buffer = audio.createBuffer(2, left.length, 44100);
      buffer.copyToChannel(left, 0);
      buffer.copyToChannel(right, 1);
      const source = audio.createBufferSource();
      source.buffer = buffer;
      source.connect(audio.destination);
      sources.add(source);
      source.onended = () => sources.delete(source);
      source.start(nextAudio);
      nextAudio += left.length / 44100;
    },
  });
  // Mount before starting the original program: its first reads must see persisted saves.
  game.FS.mkdir("/saves");
  game.FS.mount(game.IDBFS, { autoPersist: true }, "/saves");
  try {
    await new Promise((resolve, reject) =>
      game.FS.syncfs(true, (error) => (error ? reject(error) : resolve())),
    );
  } catch (error) {
    $("save-status").textContent =
      "Browser storage unavailable: saves last for this tab only.";
    console.warn(error);
  }
  status.textContent = "Your lemonade business is ready.";
  play.disabled = false;
  layout();
  requestAnimationFrame(step);
} catch (error) {
  fail(error);
}
function syncSaves() {
  if (game)
    game.FS.syncfs(false, (error) => {
      if (error) {
        $("save-status").textContent = "Could not save to browser storage.";
        console.error(error);
      }
    });
}
// Audio needs a user gesture. Keep the loading cover until the original renderer draws.
play.addEventListener("click", () => {
  try {
    ensureAudio();
    play.disabled = true;
    status.textContent = "Starting the game…";
    if (game._lemon_web_start()) {
      running = true;
      game._lemon_web_step();
    } else fail("Startup failed");
  } catch (error) {
    fail(error);
  }
});
$("sound").addEventListener("click", () => {
  muted = !muted;
  $("sound").textContent = muted ? "Sound off" : "Sound on";
  $("sound").setAttribute("aria-pressed", String(muted));
  if (muted) {
    stopAudio();
    audio?.suspend();
  } else ensureAudio();
});
$("fullscreen").addEventListener("click", async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.body.requestFullscreen();
  } catch {
    status.textContent = "Fullscreen is unavailable in this browser.";
  }
});
$("fullscreen").hidden = !document.fullscreenEnabled;
function point(event) {
  const r = canvas.getBoundingClientRect();
  return {
    x: ((event.clientX - r.left) * 640) / r.width,
    y: ((event.clientY - r.top) * 480) / r.height,
  };
}
function inField(p) {
  return (
    field &&
    p.x >= field.x - 8 &&
    p.x <= field.x + field.w + 8 &&
    p.y >= field.y - 8 &&
    p.y <= field.y + field.h + 8
  );
}
// The first outside tap dismisses text input. Consume it so it cannot also buy/confirm.
document.addEventListener(
  "pointerdown",
  (event) => {
    if (
      document.activeElement === keyboard &&
      event.target !== keyboard &&
      !inField(point(event))
    ) {
      keyboard.blur();
      consume = true;
      event.preventDefault();
      event.stopPropagation();
    }
  },
  true,
);
document.addEventListener(
  "pointerup",
  () => {
    if (consume) {
      consume = false;
      pointer = null;
    }
  },
  true,
);
// Flush input inside the tap gesture; deferring focus to a later frame can prevent
// mobile browsers from opening their software keyboard. Phases: down=0, move=1, up=2.
canvas.addEventListener("pointerdown", (event) => {
  if (!running || event.button !== 0) return;
  event.preventDefault();
  ensureAudio();
  pointer = event.pointerId;
  canvas.setPointerCapture(pointer);
  const p = point(event);
  game._lemon_touch(p.x, p.y, 0);
  game._lemon_web_flush_input();
  if (inField(p)) keyboard.focus({ preventScroll: true });
});
canvas.addEventListener("pointermove", (event) => {
  if (pointer !== event.pointerId || consume) return;
  const p = point(event);
  game._lemon_touch(
    Math.max(0, Math.min(639, p.x)),
    Math.max(0, Math.min(479, p.y)),
    1,
  );
});
function release(event) {
  if (pointer !== event.pointerId || consume) return;
  const p = point(event);
  game._lemon_touch(
    Math.max(0, Math.min(639, p.x)),
    Math.max(0, Math.min(479, p.y)),
    2,
  );
  pointer = null;
  game._lemon_web_flush_input();
}
canvas.addEventListener("pointerup", release);
canvas.addEventListener("pointercancel", release);
// The original game paints the text and caret. The transparent DOM field only
// supplies keyboard events, so its value must not duplicate the game's own text.
keyboard.addEventListener("beforeinput", (event) => {
  if (!running || !event.cancelable) return;
  if (event.inputType === "deleteContentBackward") {
    event.preventDefault();
    game._lemon_key(8);
  } else if (
    event.inputType === "insertText" ||
    event.inputType === "insertFromPaste"
  ) {
    event.preventDefault();
    for (const c of event.data || "")
      if (c.codePointAt(0) <= 255) game._lemon_key(c.codePointAt(0));
  }
  game._lemon_web_flush_input();
});
keyboard.addEventListener("input", () => {
  for (const c of keyboard.value)
    if (c.codePointAt(0) <= 255) game._lemon_key(c.codePointAt(0));
  keyboard.value = "";
  game._lemon_web_flush_input();
});
keyboard.addEventListener("paste", (event) => {
  if (!running) return;
  event.preventDefault();
  for (const c of event.clipboardData?.getData("text") || "")
    if (c.codePointAt(0) <= 255) game._lemon_key(c.codePointAt(0));
  game._lemon_web_flush_input();
});
keyboard.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    game._lemon_key(13);
    game._lemon_web_flush_input();
  }
  if (event.key === "Escape") {
    event.preventDefault();
    keyboard.blur();
  }
});
// Freeze the guest clock as well as audio, so background time does not advance a day.
document.addEventListener("visibilitychange", () => {
  active = !document.hidden;
  game?._lemon_web_active(active);
  if (!active) {
    stopAudio();
    audio?.suspend();
    syncSaves();
  } else if (audio && !muted) audio.resume().catch(() => {});
});
window.addEventListener("resize", layout);
window.visualViewport?.addEventListener("resize", layout);
document.addEventListener("fullscreenchange", layout);
window.addEventListener("pagehide", syncSaves);
