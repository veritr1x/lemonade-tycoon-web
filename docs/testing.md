# Testing the ports

Use a separate browser profile or the Simulator smoke bundle. Never replace a
player's save to run a check. Keep the browser console or device log open.

## Automated checks

```sh
python3 tools/test.py --integration
python3 tools/test_ios.py
node --test ports/web/tests/*.test.mjs
python3 tools/build.py --port web
python3 tools/build.py --port ios --smoke-test
```

For repeatable device CPU and frame measurements, see
[Performance and refresh rates](performance.md). Profiling builds use a separate
save container, and their reports stay under the ignored `build/` directory.

The C unit checks use AddressSanitizer/UndefinedBehaviorSanitizer. They cover audio
mixing and separate volume levels, pause/resume, registry persistence, allocation
reuse, portable save validation, interrupted writes, and recovery backups.
Integration checks run the original translated game: three startup/quit sessions,
original recipe, purchase, and Start Day controls, dialog and selling state, and export/import through the original loader.

The iOS and web geometry checks cover portrait stacking, widescreen, Fit/Fill,
keyboard crops, inverse touch mapping, and the Adaptive street crop. The Simulator
smoke build uses `local.lemonade.tycoon.smoketest`, a separate save container. Start
it in portrait with a fresh smoke container; inspect `Documents/smoke.json` and its
screenshots. Never uninstall the normal app as part of this check.

## Gameplay and native controls

1. Create a career in an empty slot. Exercise typing, backspace, paste, Return,
   outside-tap dismissal, and tapping the original field to reopen the keyboard.
2. Open Recipe in Adaptive's original controls column. Change an ingredient with
   its original +/− buttons. Compare the same screen in Fill and Original layouts.
3. Open Supplies in that column. Add packs, press Buy, and confirm in the original
   dialog. Check that cash and stock change, then Adaptive returns after closing.
4. Start an unstocked day with the original Start Day button at the bottom of the
   controls column. Confirm its warning remains visible. Stock the stand and start
   a selling day; the original navigation must be disabled while the day runs.
5. Finish several days, including a loss or exhausted stock. Open the original
   upgrades, location, reports, and career menus through the original controls column or the toolbar layout selector.
6. Pause/resume and background/foreground during a busy day and while holding a
   street control. Check the game clock, touch release, audio, and frame pacing.

## Layout, input, and preferences

Check phone and tablet portrait and landscape, a narrow browser window, fullscreen,
and a large Dynamic Type setting. The toolbar should float over the game in every
orientation. Hide it, confirm only the restore button remains, then restore it;
the game bounds must never change. The restore button stays inside the safe area.
iPhone must retain an 8-point inset and rounded border inside the safe area in
both orientations; check that the camera and home indicator cover no game content.
Check that a collapsed toolbar remains collapsed after relaunch.

Every Adaptive pane must keep its original proportions. Drag the divider through
its range in both orientations; all original buttons must remain visible and
respond at their new locations. Verify held game input is released, the position
survives relaunch, and portrait/widescreen remember independent positions.
Double-tap the bar to restore the balanced default. Test VoiceOver adjustments
and browser arrow keys, including Enter to reset. Interrupt a drag by rotating,
pausing, or backgrounding; it must release cleanly. Test Fill,
Fit, and Original at the pane edges and while a field is active. An outside tap
must dismiss the original text field's keyboard without pressing another control.

Change layout, mute, music/ambience, and effects; relaunch and confirm persistence.
Switch between 60 and 120 FPS while playing. Confirm the FPS counter reports new
game frames, drops to zero when paused, and resumes without including paused time
in its average. Hide the counter, then hide/restore the complete toolbar; neither
action should change the game bounds. Check both display preferences after a
relaunch, on a 60 Hz display, and in Low Power Mode. A 120 FPS preference must not
be reported as a measured 120 FPS result.
Listen to looping and one-shot sounds independently. On physical iPhone, enable
haptics and pause, then disable haptics and repeat. Simulator
checks cannot prove physical keyboard presentation, audible output, or haptic feel.

## Saves and recovery

Record the saved day, cash, recipe, and stock. Export the checkpoint, close the game,
import on the other port, and load the same slot. Export it back and repeat. Imports
replace the whole career file; confirm the pre-import backup can be exported too.
Try a truncated or modified archive and ensure the current save remains intact.
Import is disabled while a game is running. Test the previous checkpoint backup.

Reload/relaunch after an original save checkpoint, after closing normally, and after
backgrounding. Compare with the checkpoint, not an arbitrary mid-day frame. The
engine does not serialize all live simulation state. In the browser, also exercise
blocked IndexedDB and confirm the storage warning and manual export remain useful.

## Offline web app and updates

Build first, then run `python3 tools/serve.py --built --port 8000`. Editable serving
deliberately does not register a worker. Wait for **Ready to play offline**, switch
Chrome DevTools networking to Offline, reload, and load/play a saved career.

Repeat from a subdirectory URL, as GitHub Pages uses a repository path. Install the
app where supported and test a standalone launch; iOS uses Share → Add to Home Screen.
For updates, keep one old tab open, serve a second complete build, and request a
worker update. The new worker must wait; the old tab must retain its complete old
runtime. Close all old tabs and reopen to activate the new build. Incomplete or
checksum-mismatched builds must never replace a working cache.

These checks complement playthroughs; they do not establish complete original-game
parity. Record the device, build, completed checks, and any limits when reporting a
validation result.
