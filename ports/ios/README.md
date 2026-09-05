# Native iOS port

`main.m` adapts the shared C engine to UIKit and AVAudioEngine. This is a native
ARM64 app for iPhone and iPad running iOS 17 or later. It uses the same translated
game code and assets as the web port, with saves in the app's Documents directory.
Text entry automatically opens the software keyboard; tapping outside dismisses it.

## Portrait prototype

Portrait stacks the original **right column on top** and **left column below** in
equal-height panes. Both columns stay visible and interactive, including their top
status bars and bottom game buttons. **Fill screen** is the default and expands
both panes to the full available width. Both panes send input to the same running
game, so changing layout preserves progress.
While typing, the pane containing the active field brings it into view above the
docked keyboard. Tapping outside dismisses the keyboard and restores both columns.

Landscape/widescreen shows the original columns side by side. Sound and pause
controls move into a narrow rail on the right, leaving the full available height
for the game. Rotation changes the presentation without restarting the game.

The layout menu is available in both orientations:

- **Fill screen** expands the complete image into the available game area. It
  stretches the original artwork without cropping buttons or extending the game world.
- **Keep proportions** preserves image proportions, with black padding where needed.
- **Original layout** shows the complete original 640×480 view with its 4:3 proportions,
  useful for wide menus and comparison.

The choice is saved on the device.

The compact native toolbar provides pause/resume, sound, and layout controls
with VoiceOver labels and 48-point touch targets. It has no large title, including
at accessibility text sizes. Loading and restart text use Dynamic Type. The original
bitmap game menus are not yet independently accessible to VoiceOver, and their text
does not follow Dynamic Type. Native recipe/supplies forms remain future work.

Frame delivery retains only the latest pending frame. Touch cancellation releases
held game controls, including on rotation and backgrounding. Pausing or an audio
interruption freezes the shared game clock. iOS play already works offline with
bundled assets; this prototype does not add mid-day recovery checkpoints.

## Simulator

Use an Apple Silicon Mac with full Xcode installed and an iOS Simulator runtime.
Choose a simulator in Xcode and start it, then run from the repository root:

```sh
python3 tools/build.py --port ios
xcrun simctl install booted build/ios-simulator/LemonadeTycoon.app
xcrun simctl launch booted local.lemonade.tycoon
```

The builder uses Xcode's selected SDK and compiler, links Apple system frameworks,
and ad-hoc signs the simulator app. No provisioning profile is needed. Build outputs
and cached objects stay under `build/ios-simulator/`. Use `--jobs 2` to reduce parallelism.

## iPhone or iPad

Connect, trust, and unlock the device and enable Developer Mode. Use your own Apple
Development identity and a development provisioning profile that includes the device
and permits the bundle ID. Keep that profile outside this checkout.

```sh
security find-identity -v -p codesigning
xcrun devicectl list devices
python3 tools/build.py --port ios --device \
  --profile /absolute/path/to/development.mobileprovision \
  --identity YOUR_SIGNING_IDENTITY_SHA1 \
  --bundle-id local.lemonade.tycoon \
  --udid YOUR_DEVICE_UDID
xcrun devicectl device install app --device YOUR_DEVICE_IDENTIFIER build/ios-device/LemonadeTycoon.app
xcrun devicectl device process launch --device YOUR_DEVICE_IDENTIFIER local.lemonade.tycoon
```

The profile is checked for expiry, certificate, bundle ID, and (when supplied) device
UDID before compilation. The device app is signed and verified under `build/ios-device/`.
No IPA is produced or published by this workflow. Profiles, certificates, private keys,
app bundles, and IPA archives are excluded from Git.

## Implementation and checks

The engine runs on a worker thread. Frame callbacks copy pixels before scheduling
UIKit updates on the main thread. `GameView.m` uses the source/display rectangles in
`layout.h` for both drawing and touch mapping into the original 640×480 coordinates,
and forwards `UIKeyInput` characters. Audio session changes run on the main
thread; AVAudioEngine renders the shared PCM mixer. Backgrounding pauses the engine
clock, and a normal game exit offers **Play again** with the existing saves.

Run `python3 tools/test.py --integration` for the shared runtime. After an iOS change,
also launch the app and check career creation, keyboard appearance/editing/dismissal,
sound, background/resume, save/relaunch, and Quit → Play again. Simulator checks do not
establish physical-device keyboard or audio behavior. Broad iPad layout and gameplay
coverage still need device testing.

Run `python3 tools/test_ios.py` on macOS for sanitized coordinate/crop checks.
For a simulator host smoke test, use a disposable test app:

```sh
python3 tools/build.py --port ios --smoke-test
# Remove only the test app before repeating a run, so its save slots start empty.
xcrun simctl uninstall booted local.lemonade.tycoon.smoketest
xcrun simctl install booted build/ios-smoke/LemonadeTycoon.app
xcrun simctl launch --console booted local.lemonade.tycoon.smoketest
```

The test app uses synthesized UIKit touch calls to exercise pane mapping, character
entry, outside dismissal, reopening, Return, touch release, pause/resume, and layout
switching, including the compact toolbar height. It writes `smoke.json` and screenshots
to its own Documents directory. Also rotate the simulator into both landscape
directions, use a recipe button, and return to portrait to check layout and progress.
These checks do not replace physical touch, VoiceOver, or software-keyboard testing.
The smoke-test code is excluded from normal builds and cannot target a device.
