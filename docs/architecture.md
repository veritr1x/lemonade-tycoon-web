# How the browser port works

## Start here

Follow `web/app.js` → `native/web/host.c` → `native/platform.c` when debugging a
browser interaction. The page shell is intentionally framework-free. The original
game still owns its menus, simulation, text, and bitmap drawing.

## Original code and guest memory

`tools/lift_game.py` translates the original x86 instructions into C ahead of time.
`native/generated/` contains 97 pages of this code plus a dispatcher. Emscripten
compiles those ordinary C functions to WebAssembly; no x86 decoder runs in the browser.

The `CPU` structure in `native/runtime.h` holds original registers, arithmetic flags,
floating-point state, and a byte array representing guest memory. Original addresses
index that array. They are never used as executable host pointers. `rd`/`wr` check
memory bounds; translated instructions record an explicit fault when unsupported.

Startup loads `assets/cold-memory.bin` at guest address `0x400000`, replaces imports
with synthetic API thunks, configures the standalone full-game path, and enters the
original CRT at `0x44fb6b`. `native/game_config.h` documents the configuration globals.

## Windows API boundary

`native/platform.c` implements the reached Win32 APIs. Guest import addresses beginning
at `0xf0000000` route to `native_api`; `native/generated/imports.h` maps their names.
The adapter reads arguments from the guest stack and applies stdcall cleanup with
`RET`. Host handles refer to local tables for files, windows, drawing objects, and
allocations. A window callback can re-enter translated code through `game_run`.

File access is limited to resource and save directories. GDI operations eventually
produce a 640×480 RGB framebuffer. `native/registry.h` stores registry/profile values
in a sandbox file and replaces that file through a temporary write and rename.

## Cooperative browser loop

`lemon_web_step` retains the program counter between calls. It returns after an
original Sleep call or a roughly 8 ms budget, letting the browser paint and handle
events. A dispatch itself cannot be preempted. Nested window callbacks still run
synchronously, so unusually long callback paths remain a performance boundary.

`web/app.js` calls the step function from `requestAnimationFrame`. A guest fault or
process exit closes files/audio, frees guest memory, and restores **Play again**.
The lifecycle clock excludes background time; resuming a tab does not jump ahead.

## Pixels and input

The host converts packed RGB words to a fresh RGBA byte array for `ImageData`.
Canvas CSS size preserves 4:3; pointer coordinates are scaled back to 640×480.
The pointer adapter sends original window messages with down/move/up phases.

Hooks at the original text editor's activation/deactivation addresses update a
transparent DOM input. Widget ancestors determine visibility and screen bounds.
The original game draws text and caret; the DOM input supplies character, deletion,
paste, and Return events. The first tap outside dismisses the field and is consumed
so it cannot also activate a game button. Input flushing waits for queued messages
and a redraw within a bounded gesture update so first focus can happen during a tap.

## Sound and saves

`native/audio.c` implements the reached FMOD sample calls. It mixes samples into
stereo float buffers, including volume, pause, mute, looping, and resampling.
The browser copies them into Web Audio buffers at 44.1 kHz and queues about 120 ms.
Audio starts after a user gesture and is stopped on pause, mute, or quit.

Before startup, the page mounts IDBFS at `/saves` and loads IndexedDB contents.
The original `Lemonade.dat` and the adapter's `registry.bin` keep their formats.
IDBFS persists writes automatically, with explicit synchronization on backgrounding
and exit. This persists the game's existing save points; it does not create a
mid-day snapshot. Storage is local to the site's browser origin, not an account.

## Build and publishing

`tools/build.py` compiles cached objects and emits `build/site/`. The linker limits
Binaryen single-caller inlining: the default previously combined the engine into a
14 MB function rejected by Chrome. The resulting module is validated with Node/V8.
Relative asset URLs allow deployment under a GitHub Pages repository path.

The workflow builds from source, uploads only the site artifact, and deploys `main`.
`build.json` records the source revision and runtime checksums. `tools/serve.py` can
download that runtime for interface contributors; it serves current files from
`web/` directly and exposes no other workspace files.

## Current boundaries

- Unsupported translated instructions and Windows APIs fault explicitly. Reachability
  of every decoded instruction is not established; the coverage report includes
  bytes decoded from embedded data as well as actual code.
- x87 uses host double precision rather than full 80-bit extended precision.
- The adapter covers tested game paths, not the complete Win32 or FMOD APIs.
- Historical network services have not been restored or verified.
- Current text forwarding covers the original single-byte input range; complex
  composition and international input methods need further work.
- Mobile viewport checks do not replace a physical Safari keyboard test.
- Long campaigns, every game mode, and broad browser parity need more testing.
