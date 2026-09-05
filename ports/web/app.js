import createLemonade from "./lemonade.js";
import { SaveControls } from "./saves.js";
import { GameSurface } from "./layout.js";
import { AdaptiveSplitter } from "./splitter.js";
import { setupOffline } from "./offline.js";
import {
  readPreference,
  writePreference,
  setupVolumes,
} from "./preferences.js";
const money = (cents) => `$${(cents / 100).toFixed(2)}`;
const $ = (id) => document.getElementById(id),
  canvas = $("game");
const keyboard = $("keyboard"),
  cover = $("cover"),
  status = $("status"),
  play = $("play");
let game,
  running = false,
  active = true,
  userPaused = false,
  field = null,
  pointer = null,
  consume = false,
  audio = null,
  masterGain = null,
  nextAudio = 0,
  muted = readPreference("soundMuted", false) === true,
  frames = 0;
// Track scheduled audio so pause, mute, and quit can stop every queued sample.
const sources = new Set();
const surface = new GameSurface(canvas, cancelPointer);
const splitter = new AdaptiveSplitter(
  $("adaptive-divider"),
  $("screen"),
  layout,
  cancelPointer,
);
const applyVolumes = setupVolumes(() => game);
let lastPoint = { x: 0, y: 0 },
  layoutMode = "adaptive",
  gameState;
try {
  layoutMode = localStorage.getItem("gameLayout") || "adaptive";
} catch {}
if (!["fill", "fit", "original", "adaptive"].includes(layoutMode))
  layoutMode = "adaptive";
$("layout").value = layoutMode;
$("layout").addEventListener("change", () => {
  keyboard.blur();
  layoutMode = $("layout").value;
  try {
    localStorage.setItem("gameLayout", layoutMode);
  } catch {}
  layout();
});
const saves = new SaveControls({
  game: () => game,
  running: () => running,
  sync: syncSaves,
  close: () => {
    userPaused = false;
    refreshActivity();
    game._lemon_request_quit();
  },
});
let saveRevision = 0,
  saveSync = Promise.resolve(true);
$("settings").addEventListener("click", () => {
  if (game) game._lemon_web_read_state();
  $("settings-dialog").showModal();
});
$("close-settings").addEventListener("click", () =>
  $("settings-dialog").close(),
);
// Overlay visibility is independent of the canvas geometry and pause state.
function setControlsHidden(hidden, focus = false) {
  cancelPointer();
  keyboard.blur();
  $("controls").hidden = hidden;
  $("show-controls").hidden = !hidden;
  $("show-controls").setAttribute("aria-expanded", String(!hidden));
  document.body.classList.toggle("controls-hidden", hidden);
  writePreference("controlsHidden", hidden);
  if (focus)
    $(hidden ? "show-controls" : "hide-controls").focus({
      preventScroll: true,
    });
}
$("hide-controls").addEventListener("click", () =>
  setControlsHidden(true, true),
);
$("show-controls").addEventListener("click", () =>
  setControlsHidden(false, true),
);
setControlsHidden(readPreference("controlsHidden", false) === true);
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
  if (!audio) {
    audio = new AudioContext();
    masterGain = audio.createGain();
    masterGain.connect(audio.destination);
  }
  masterGain.gain.value = muted ? 0 : 1;
  if (active) audio.resume().catch(() => {});
}
// Keep a short Web Audio queue: enough to absorb rendering jitter without laggy effects.
function pumpAudio() {
  if (!audio || audio.state !== "running" || !running) return;
  if (nextAudio < audio.currentTime) nextAudio = audio.currentTime + 0.025;
  for (let i = 0; i < 4 && nextAudio < audio.currentTime + 0.12; i++)
    game._lemon_web_audio(2048);
}
// The source stays 640×480; the visible canvas composes independently mapped panes.
function layout() {
  document.body.style.height = `${window.visualViewport?.height || innerHeight}px`;
  const adaptive =
    layoutMode === "adaptive" &&
    running &&
    gameState?.loaded &&
    !gameState.modal &&
    !field;
  $("stage").classList.toggle("adaptive", adaptive);
  $("adaptive-hud").hidden = !adaptive;
  const stage = $("screen");
  splitter.update(adaptive && active);
  surface.resize(stage.clientWidth, stage.clientHeight, {
    mode: adaptive
      ? "adaptive"
      : layoutMode === "adaptive"
        ? "fill"
        : layoutMode,
    portrait: innerWidth <= innerHeight,
    split: splitter.value(stage.clientWidth > stage.clientHeight),
    field,
    keyboardOpen: document.activeElement === keyboard,
  });
  if (!field) return;
  const rect = surface.fieldRect(field);
  if (!rect) return;
  Object.assign(keyboard.style, {
    left: `${rect.x}px`,
    top: `${rect.y}px`,
    width: `${rect.w}px`,
    height: `${rect.h}px`,
  });
}
function cancelPointer() {
  if (pointer !== null && running && game)
    game._lemon_touch(lastPoint.x, lastPoint.y, 2);
  pointer = null;
}
function refreshActivity() {
  active = !document.hidden && !userPaused;
  if (!active) {
    cancelPointer();
    splitter.cancel();
  }
  game?._lemon_web_active(active);
  $("pause").textContent = userPaused ? "▶" : "Ⅱ";
  $("pause").setAttribute("aria-pressed", String(userPaused));
  $("pause").setAttribute(
    "aria-label",
    userPaused ? "Resume game" : "Pause game",
  );
  $("pause").title = userPaused ? "Resume game" : "Pause game";
  $("paused").hidden = !userPaused || !running;
  if (!active) {
    stopAudio();
    audio?.suspend();
  } else if (audio) audio.resume().catch(() => {});
  layout();
}
$("pause").addEventListener("click", () => {
  keyboard.blur();
  userPaused = !userPaused;
  refreshActivity();
});
keyboard.addEventListener("focus", layout);
keyboard.addEventListener("blur", layout);
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
    onGameState(state) {
      const changed =
        gameState?.loaded !== state.loaded || gameState?.modal !== state.modal;
      gameState = state;
      $("stand-cash").textContent = `Cash ${money(state.cash)}`;
      $("stand-price").textContent = `Price ${money(state.price)} / cup`;
      if (changed) layout();
    },
    onSaveState(state) {
      saves.update(state);
      if (state.revision !== saveRevision) {
        saveRevision = state.revision;
        if (!state.result)
          syncSaves().then((ok) => {
            if (ok && saveRevision === state.revision)
              $("save-status").textContent =
                `Checkpoint saved · ${new Date(state.saved * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}`;
          });
        else
          $("save-status").textContent =
            "Checkpoint could not be saved. Previous save retained.";
      }
    },
    onGameFrame(pixels, w, h) {
      surface.frame(pixels, w, h);
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
      userPaused = false;
      refreshActivity();
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
      if (!audio || audio.state !== "running") return;
      const buffer = audio.createBuffer(2, left.length, 44100);
      buffer.copyToChannel(left, 0);
      buffer.copyToChannel(right, 1);
      const source = audio.createBufferSource();
      source.buffer = buffer;
      source.connect(masterGain);
      sources.add(source);
      source.onended = () => sources.delete(source);
      source.start(nextAudio);
      nextAudio += left.length / 44100;
    },
  });
  if (!game._lemon_web_read_state || !game._lemon_audio_levels)
    throw new Error(
      "The page needs its matching runtime. Build this checkout with tools/build.py --port web.",
    );
  // Mount before starting the original program: its first reads must see persisted saves.
  game.FS.mkdir("/saves");
  game.FS.mount(game.IDBFS, {}, "/saves");
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
  applyVolumes();
  updateSoundButton();
  refreshActivity();
  play.disabled = false;
  layout();
  requestAnimationFrame(step);
  setupOffline();
  setInterval(() => game._lemon_web_read_state(), 250);
} catch (error) {
  fail(error);
}
function syncSaves() {
  if (!game) return Promise.resolve(false);
  saveSync = saveSync.then(
    () =>
      new Promise((resolve) => {
        game.FS.syncfs(false, (error) => {
          if (error) {
            $("save-status").textContent = "Could not save to browser storage.";
            console.error(error);
          }
          resolve(!error);
        });
      }),
  );
  return saveSync;
}
// Audio needs a user gesture. Keep the loading cover until the original renderer draws.
play.addEventListener("click", () => {
  try {
    ensureAudio();
    userPaused = false;
    refreshActivity();
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
  writePreference("soundMuted", muted);
  updateSoundButton();
  ensureAudio();
});
function updateSoundButton() {
  $("sound").textContent = muted ? "♫̸" : "♪";
  $("sound").setAttribute("aria-label", muted ? "Unmute sound" : "Mute sound");
  $("sound").title = muted ? "Unmute sound" : "Mute sound";
  $("sound").setAttribute("aria-pressed", String(muted));
}
$("fullscreen").addEventListener("click", async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.body.requestFullscreen();
  } catch {
    status.textContent = "Fullscreen is unavailable in this browser.";
  }
});
$("fullscreen").hidden = !document.fullscreenEnabled;
function point(event, held = false) {
  return surface.point(event, held);
}
function inField(p) {
  return (
    field &&
    p &&
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
    const editing = document.activeElement;
    if (
      editing === keyboard &&
      event.target !== keyboard &&
      !inField(point(event))
    ) {
      editing.blur();
      consume = true;
      consumeClick = true;
      event.preventDefault();
      event.stopPropagation();
    }
  },
  true,
);
let consumeClick = false;
document.addEventListener(
  "click",
  (event) => {
    if (consumeClick) {
      consumeClick = false;
      event.preventDefault();
      event.stopImmediatePropagation();
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
      setTimeout(() => {
        consumeClick = false;
      }, 400);
    }
  },
  true,
);
// Flush input inside the tap gesture; deferring focus to a later frame can prevent
// mobile browsers from opening their software keyboard. Phases: down=0, move=1, up=2.
canvas.addEventListener("pointerdown", (event) => {
  if (!running || !active || splitter.drag || event.button !== 0) return;
  const p = point(event);
  if (!p) return;
  surface.begin(event);
  lastPoint = p;
  event.preventDefault();
  ensureAudio();
  pointer = event.pointerId;
  canvas.setPointerCapture(pointer);
  game._lemon_touch(p.x, p.y, 0);
  game._lemon_web_flush_input();
  if (inField(p)) keyboard.focus({ preventScroll: true });
});
canvas.addEventListener("pointermove", (event) => {
  if (pointer !== event.pointerId || consume) return;
  const p = point(event, true);
  if (!p) return;
  lastPoint = p;
  game._lemon_touch(
    Math.max(0, Math.min(639, p.x)),
    Math.max(0, Math.min(479, p.y)),
    1,
  );
});
function release(event) {
  if (pointer !== event.pointerId || consume) return;
  const p = point(event, true);
  if (!p) return;
  lastPoint = p;
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
  refreshActivity();
  if (document.hidden) syncSaves();
});
window.addEventListener("resize", layout);
window.visualViewport?.addEventListener("resize", layout);
document.addEventListener("fullscreenchange", layout);
window.addEventListener("pagehide", syncSaves);
