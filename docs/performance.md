# Performance and refresh rates

Choose **60 FPS** or **120 FPS** in Settings & saves. The preference is a limit,
not a promise of that frame rate. The default is 120; 60 reduces rendering work
when the engine can run faster. The FPS counter counts new game frames presented
by the host, including a static frame if the original game redraws it. It does not
count timer callbacks, repeated display refreshes, or layout-only redraws. Static
menus can show 0 FPS. The counter can be hidden independently and hides with the
floating controls without changing the game bounds.

iOS uses one `CADisplayLink`, requests ProMotion timing, and follows the refresh
rate granted by the system. It caps the preference at the screen maximum and at
60 in Low Power Mode. These are timing hints; iOS can choose a different rate.
See Apple's [ProMotion guidance](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays).
The browser uses `requestAnimationFrame`; a 60 Hz browser/display cannot present
120 FPS. Both hosts suspend recurring game/HUD callbacks while paused or hidden.

## Repeatable iPhone/iPad workload

The benchmark build uses a separate `.benchmark` bundle and resets only that
bundle's preferences and Documents directory on launch. It never opens the normal
app's careers. Use a development profile that permits the suffixed bundle ID.

```sh
python3 tools/build.py --port ios --device --benchmark \
  --profile /absolute/path/to/development.mobileprovision \
  --identity YOUR_SIGNING_IDENTITY_SHA1
xcrun devicectl device install app --device YOUR_DEVICE_IDENTIFIER \
  build/ios-benchmark-device/LemonadeTycoon.app
xcrun devicectl device process launch --device YOUR_DEVICE_IDENTIFIER \
  local.lemonade.tycoon.benchmark
```

Keep the app in the foreground for about 2½ minutes. It measures the main menu,
creates an isolated career, measures Adaptive at 60 and 120, pauses, then uses
the original Supplies and Start Day buttons and measures selling at both rates.
Each phase lasts at least 20 seconds. A failed purchase/start assertion invalidates
the workload. The app closes its game after writing `result: passed`.

```sh
xcrun devicectl device copy from --device YOUR_DEVICE_IDENTIFIER \
  --source Documents/performance.json --destination build/device-performance.json \
  --domain-type appDataContainer \
  --domain-identifier local.lemonade.tycoon.benchmark
```

Wait for the copy to finish, then check `result` before comparing measurements.
The report contains process CPU time divided by actual elapsed wall time
(100% means one CPU core), physical memory footprint, generated/delivered frames,
delivery interval percentiles, display-link callbacks, HUD polls, thermal state,
Low Power Mode, brightness, and charging state. Host image delivery is not a
physical display scanout measurement. The benchmark hooks are absent from normal
builds. Reports, traces, signing files, apps, and saves stay under ignored `build/`.

## Browser comparison

Build both revisions and serve each on a separate port. Use isolated browser
profiles and a fresh career for each run. Keep browser version, viewport, display,
power mode, and other system activity comparable. In Chrome's Performance panel,
record an idle stand, a stocked selling day, and a paused game separately. Compare
new canvas frames, long tasks, scripting time, and recurring callbacks. Keep the
baseline page loaded with its original runtime until the comparison is complete.

Count new presentations per animation frame, not every intermediate canvas blit.
Exercise pause/resume repeatedly and switch tabs: paused/hidden pages should have
no recurring engine frame requests or HUD polls. Also check input, normal saves,
quit/restart, and setting persistence after changes to the scheduling budget.

## CPU findings and power limits

The native sample located substantial work in translated software drawing and
arithmetic. Compiler/inlining experiments did not produce a useful improvement on
the devices, so they were discarded. Redraw pacing includes time spent rendering,
waits only when ahead of its deadline, and resets after long pauses instead of
replaying missed frames. A 120 Hz display request alone does not make a CPU-bound
renderer deliver 120 new game frames per second.

The browser profile found excessive crossings into JavaScript for scheduling
timestamps. The host now checks its 8 ms cooperative budget every 32 translated
dispatches. Original Sleep still yields immediately. A single translated call can
exceed the budget, so compare long tasks and input responsiveness after changes.
Unchanged cash/price text no longer triggers repeated layout.

CPU percentages are useful for locating work, but they are not watts or battery
life estimates. For energy comparisons, use Instruments **Power Profiler** on the
same physical device, with fixed brightness, comparable thermal state, and the
device unplugged. Apple notes that overall power usage reads zero while charging.
See [Measuring power use with Power Profiler](https://developer.apple.com/documentation/Xcode/measuring-your-app-s-power-use-with-power-profiler).
Wait for Xcode device preparation to finish before recording. Include the OS,
build, requested and delivered frame rates, and charging state with every result.

## Initial build 16 measurements — 2026-09-06

Baseline: local main `404779c` (build 15). Comparison: local build 16. Both devices
completed the isolated workload; the current run ignored physical touches and
verified that the requested rate stayed unchanged throughout each phase. All
recorded thermal states were nominal. These are individual short runs, not a
statistical battery test.

| Device / phase                         | Baseline CPU (one core) | Build 16 at 60 FPS |
| -------------------------------------- | ----------------------: | -----------------: |
| iPhone 15 Pro (26.6.1), menu           |                   3.94% |              2.34% |
| iPhone 15 Pro (26.6.1), idle stand     |                  94.24% |             94.33% |
| iPhone 15 Pro (26.6.1), paused         |                   0.69% |              0.01% |
| iPhone 15 Pro (26.6.1), selling        |                  94.63% |             94.75% |
| iPad Pro 11-inch M4 (26.6), menu       |                   2.64% |              1.99% |
| iPad Pro 11-inch M4 (26.6), idle stand |                  93.76% |             95.90% |
| iPad Pro 11-inch M4 (26.6), paused     |                   0.64% |              0.01% |
| iPad Pro 11-inch M4 (26.6), selling    |                  94.03% |             94.92% |

Pausing stopped all HUD polls and display-link callbacks. Active native CPU use
remained about one core; the bottleneck was the translated software renderer.

| Device / scene            | Delivered at 60 FPS setting | Delivered at 120 FPS setting |
| ------------------------- | --------------------------: | ---------------------------: |
| iPhone 15 Pro, idle stand |                    55.1 FPS |                     53.3 FPS |
| iPhone 15 Pro, selling    |                    51.4 FPS |                     50.5 FPS |
| iPad Pro M4, idle stand   |                    58.8 FPS |                     57.3 FPS |
| iPad Pro M4, selling      |                    49.5 FPS |                     49.4 FPS |

Both devices supplied about 120 display-link callbacks per second in the 120
phases. New game frames were slower, as the table shows. The counter reports the
new frames. These findings led to the build 17 optimizations described below.
The new display-link delivery boundary also means
its interval percentiles should not be read as physical scanout comparisons with
the older asynchronous image callbacks.

Chrome 152 on the local Mac, at a 1200×863 viewport, delivered 11.7–12.5 new game
FPS in two current 20-second idle-stand runs. The initial baseline delivered 4.65
FPS. Current runs recorded no tasks of 50 ms or longer; the p95 scheduling slice
was about 10–11 ms including host work. Background tooling activity was not fully
controlled, so use these as local diagnostics rather than portable guarantees.

Raw local reports are `build/iphone-baseline.json`, `build/ipad-baseline.json`,
`build/iphone-release.json`, `build/ipad-release.json`,
`build/web-baseline-pacing.json`, `build/web-release-pacing.json`, and
`build/web-verified-measure-result.json`. These files are intentionally not
committed. Brightness and charging
state changed between native runs, so no energy or battery-life saving is inferred
from the CPU figures. A usable Power Profiler capture was not obtained in this run.

Validation passed on the final build: 41 host interaction checks on each iPhone
and iPad simulator, 3,134 instruction comparisons against Unicorn, the native
integration suite, and the web geometry tests. Browser checks exercised a fresh
career, all four ingredient purchases, Start Day, pause/resume, the display
settings, and close/restart. Normal build 16 was installed and launched on both
physical devices; the temporary benchmark apps were then removed.

## Build 17: cap audit and renderer changes

The 60 FPS observation was not a signing-entitlement problem. Both signed apps
already contained `CADisableMinimumFrameDurationOnPhone = true`, and physical
measurements showed about 120 display-link callbacks per second during the 120
phases. The normal apps' saved preferences also used the default 120 FPS setting.
Apple documents the Info.plist key and display-link frame-rate range as the
[ProMotion configuration](https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays).

A headless native audit counted one `GetTickCount` and one `Sleep(1)` per game
frame in an idle stand. Removing sleep entirely produced about 69 FPS on the Mac;
honoring the 120 FPS deadline produced about 68. The clock was not busy-waiting
for a hidden 60 FPS gate. These instrumented figures are diagnostic and do not
include UIKit image presentation.

The fastest measured route was to accelerate a few original drawing loops:

- Plain 16-bit rows crossed a generated page boundary twice per pixel: about
  1.2 million dispatches per frame. Joining the pages alone did not help.
  Replacing the seven translated instructions per pixel with a checked bulk
  copy raised the headless idle result from about 69 to 134 FPS.
- GDI conversion repeatedly calculated coordinates, bit masks, and channel
  divisions. Common unscaled RGB555/565 frames now use an exact lookup table.
  Tests compare every possible 16-bit color, both row orders, padding, offsets,
  and destination guards against the generic decoder.
- Busy selling scenes exposed a color-keyed sprite/palette loop. Its fast path
  skips transparent pixels and retains the original palette mapping.
- The native late-frame path still added a 1 ms sleep. After the drawing changes,
  that delay could hold a nearly fast-enough frame loop below 120. Late frames now
  continue immediately; frames ahead of their deadline still wait normally.

Both row helpers preserve registers, arithmetic flags, pixels, and original
instruction counts. Invalid bounds, aliasing, unusual strides, and insufficient
instruction budgets use the original code. The generator checks the original
loop bytes before producing the hooks. The oracle now includes 1,000 row cases
among 4,134 comparisons; sanitized fallback tests and full-game integration
checks also pass. No simulation clock or day-speed multiplier was changed.

### Final build 17 device results — 2026-09-06

Both physical devices completed the isolated workload with `result: passed`.
Each active phase lasted about 20 seconds. Thermal state remained nominal and
Low Power Mode was off. The 120 FPS phases delivered a new image on every
recorded display-link callback:

| Device / scene | Delivered FPS | Delivery p95 | CPU (one core) |
| --- | ---: | ---: | ---: |
| iPhone 15 Pro, idle stand | 119.96 | 8.352 ms | 59.8% |
| iPhone 15 Pro, selling | 119.98 | 8.355 ms | 68.9% |
| iPad Pro 11-inch M4, idle stand | 120.00 | 8.339 ms | 63.1% |
| iPad Pro 11-inch M4, selling | 120.00 | 8.344 ms | 67.6% |

These are host image deliveries, not physical scanout measurements or a guarantee
for every scene. Weather and customer traffic vary between fresh careers, so
successive runs are not perfectly matched workloads. The iPhone's 60 FPS idle
phase included a 1.54-second display-link interruption and averaged 55.4 delivered
FPS; its 120 FPS phases had no such interruption. Paused phases generated no
frames, display callbacks, or HUD polls on either device.

The final Chrome selling run delivered 58.5 new game FPS, with no tasks of 50 ms
or longer. An independent animation-frame timestamp sample measured 120.02 Hz;
the browser's display rate therefore did not explain the remaining gap in that
run. Earlier idle measurements near 60 FPS should not be treated as proof of a
60 Hz display cap. Further web profiling must distinguish cooperative scheduling,
Wasm rendering, and canvas presentation before choosing another optimization.
Purchasing all four ingredients, starting a day, pausing, hiding the counter,
changing the limit, and closing/restarting passed. The preview was restored to
120 FPS with the counter visible after checking saved 60 FPS preferences.

Final validation passed: 4,134 original-instruction comparisons, sanitized renderer
and platform tests, full-game native integration, web geometry checks, and 41 host
checks on each iPhone and iPad simulator. Normal build 17 was installed and launched
on both physical devices without deleting their app data. The isolated benchmark
apps were removed afterward. All changes remain local.

Raw reports remain ignored under `build/`: `renderer-iphone-release.json`,
`renderer-ipad-release.json`, `renderer-release-web-result.json`, and
`renderer-browser-refresh.json`. Installation and launch results are recorded in
`renderer-build17-{iphone,ipad}-{install,launch}.json`.
