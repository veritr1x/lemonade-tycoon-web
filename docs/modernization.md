# Modern interface and saves

The local preview adds layout choices and save transfers around the original simulation. Choose
**Adaptive** in the web layout selector or **Adaptive interface** in the iOS layout
menu. Existing layout preferences are kept; new installations start with Adaptive.
The original menus remain available in the controls column or the toolbar's **Fill** and **Original** layouts. Game dialogs
temporarily show the original screen so their controls stay reachable.

## Where to contribute

| Change                         | Shared code                            | Web                                           | iOS                                         |
| ------------------------------ | -------------------------------------- | --------------------------------------------- | ------------------------------------------- |
| HUD state                      | `engine/game.h`, `engine/game_state.h` | `app.js`, `host.c`                            | `DashboardView.m`                           |
| Layout and pointer mapping     | Original 640 × 480 coordinate system   | `layout.js`, `splitter.js`, `style.css`       | `layout.h`, `GameView.m`, `DashboardView.m` |
| Save transactions and transfer | `engine/save.c`, `engine/save.h`       | `saves.js`, `app.js`                          | `SettingsController.m`                      |
| Audio levels                   | `engine/audio.c`, `engine/audio.h`     | `preferences.js`, `app.js`                    | `SettingsController.m`, `main.m`            |
| Offline installation           | Build manifest and hashes              | `sw.js`, `offline.js`, `manifest.webmanifest` | Assets already bundled                      |

Paths in the platform columns are relative to `ports/web/` and `ports/ios/`.
Use the existing modules rather than putting another copy of the rules in a host.

## Game state

Hosts read a copied `LemonGameState` at the cooperative Sleep boundary. All
recipe, purchase, and day actions use the original game controls, preserving the
original dialogs and warnings.

The worker owns guest memory; UIKit only reads the copied snapshot. The browser
bridge converts that snapshot into a JavaScript object without depending on C
structure offsets. Cash and price use integer cents.

The pinned HUD bindings live in `engine/game_state.h`: the game model is at
`0x47dbd4` and the game view at `0x4d3060`. Keep these addresses out of platform UI
code. If the cold image changes, recheck the bindings and run the original-game
integration test in `engine/tests/gameplay.c`.

## Save behavior

The game retains its normal save points. Export does not take a mid-day memory
snapshot. It transfers all careers in the latest completed `Lemonade.dat`, without
device settings. Use **Settings & saves** to export, share, or import a file.

Writes go to `Lemonade.dat.pending`. The original CloseHandle commits the completed
file by rename, after retaining `Lemonade.dat.bak`. Fault/exit cleanup discards an
unfinished write. Import validates the archive before writing and refuses to run
while the engine is open. It keeps `Lemonade.before-import.dat` separately, so a
subsequent automatic save does not immediately remove the recovery copy.

The `.lemonade-save` envelope is deliberately small:

| Bytes     | Meaning                                |
| --------- | -------------------------------------- |
| 0–7       | ASCII `LEMONSV1`                       |
| 8–11      | Payload length, little-endian uint32   |
| 12–15     | CRC32 of payload, little-endian uint32 |
| 16 onward | Original compressed `Lemonade.dat`     |

Length is limited to 8 MiB. Version, length, original format bytes, and checksum
must match. CRC detects damaged transfers; it is not an authenticity signature.
The original serializer remains responsible for the payload's game data.

On the web, completed checkpoints also await IDBFS synchronization before showing
**Checkpoint saved**. Storage errors stay visible. Clearing site data removes local
progress and offline files, so keep an exported copy of important careers.

## Layout, sound, and accessibility

Fill expands the original columns; Fit preserves their proportions; Original
shows the complete 4:3 surface. Adaptive separates weather and street crops from
readable cash/price information and the complete original controls column. The
street, weather, and controls keep their original proportions. The divider starts
with 52% of the portrait height for controls, or 48% of the widescreen width.
Drag the bar between panes to change this live. Double-tap (double-click on web)
to reset; VoiceOver adjusts the iOS divider, and browser arrow keys move it.
Enter resets the browser divider; Home and End select the size limits.

Each orientation remembers its own controls fraction in `adaptivePortraitSplit`
and `adaptiveWideSplit`. Fractions stay between 25% and 78%, with a minimum
112-point pane where space allows. The visible bar is 16 points wide, surrounded
by a 44-point hit area. `layout.h` and `layout.js` define the geometry;
`DashboardView.m` and `splitter.js` handle gestures and preferences. Moving the
divider releases held game input before repainting and updating touch mapping.
Rotation, pause, dialogs, and text entry end a drag safely. Drawing and pointer
input share the same source crops throughout.

The toolbar floats over the game instead of reserving a row or side strip.
**Hide controls** leaves a small **Show controls** button. Visibility is remembered
independently from layout and pause, so hiding or restoring it cannot change the
play area. iOS keeps overlays inside the safe area. iPhone adds an 8-point inset
and a thin rounded border inside that area, clear of the camera and home indicator;
iPad uses the full screen. Both respond to the docked keyboard.

Native settings use Dynamic Type and accessible labels. Browser settings use
semantic labels, buttons, and status messages. Original bitmap menus and weather
text do not yet provide full screen-reader navigation.

Music/ambience volume applies to looping background channels; effects volume
applies to one-shot channels. Both multiply the original game's volume and mute
settings. Muting output keeps playback position advancing. Pausing or backgrounding
freezes simulation and audio. iOS pause haptics are optional and off by default.

## Offline builds and local checks

Build the web port, then run `python3 tools/serve.py --built --port 8000` to check
the complete installable app. Normal `tools/serve.py` serves editable shell files
and does not serve a service worker, so caching cannot hide interface edits.

The builder generates a worker with hashes for every shell and runtime asset.
Installation fails if any download is missing or belongs to another build. Existing
tabs retain their cached build; a new worker waits for those tabs to close. Saves
are in IndexedDB and never enter the asset cache. The service-worker lifecycle
follows [MDN's service worker guidance](https://developer.mozilla.org/en-US/docs/Web/API/Service_Worker_API/Using_Service_Workers).

Run `python3 tools/test.py --integration`, `node --test ports/web/tests/*.test.mjs`,
and, on macOS, `python3 tools/test_ios.py`. Build both ports after changing a shared
header. The simulator smoke app uses a separate bundle and disposable careers.
See [the testing checklist](testing.md) for transfer, offline, and device checks.
