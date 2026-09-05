# Browser checks

Use a separate browser profile or save slot so testing does not overwrite a game.
Open the console and keep it free of unexpected errors during these checks.

1. Press **Play** and wait for the original main menu.
2. Create a career in an empty slot. Check immediate field focus, typing, backspace,
   paste, outside-tap dismissal, tapping to reopen, and Return to confirm.
3. Buy supplies, adjust the recipe, and finish a day using the original controls.
4. Record the day, cash, and inventory. Reload the page, press Play, and load the
   career. Those values should match the game's saved checkpoint.
5. Toggle sound, background/resume the tab, and check that playback does not pile up.
6. Enter and leave fullscreen. Try portrait and landscape, including a small viewport.
   Check coordinate mapping at the edges and that controls stay above the keyboard.
7. Use the original Quit dialog, then **Play again**. Reload the same save once more.

For performance changes, also watch input latency and frame pacing through a busy
day. For storage changes, check blocked IndexedDB, page reload, and quit/restart.
For mobile keyboard changes, test a physical device: viewport emulation only proves
layout and focus state, not software-keyboard presentation.

## Automated coverage

`python3 tools/test.py` exercises PCM playback/resampling, lifecycle pause/resume,
nested runtime exit, registry persistence, buffer sizes, and allocation reuse with
AddressSanitizer/UndefinedBehaviorSanitizer.

`--integration` adds original configuration checks, URL handling, and three complete
startup/main-menu/quit/CRT-exit sessions in one native process. The optional
`engine/tests/differential.py` compares translated original routines against Unicorn.
The WebAssembly build also validates its output with V8. These checks complement
browser playthroughs; they do not establish full game parity.
