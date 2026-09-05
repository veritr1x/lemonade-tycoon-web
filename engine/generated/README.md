# Generated original-game code

Do not hand-edit or reformat these files. `page_*.c` preserves original addresses
and disassembly comments so faults can be traced back to an instruction. The
dispatcher routes between pages; `imports.h` defines the Windows API thunks.
The generated code also recognizes the measured plain and color-keyed 16-bit
row-copy hotspots. Their checked implementations live in `engine/renderer.h`;
other cases run the original instructions. The generator verifies each loop's
original bytes before adding a hook. Differential tests compare pixels,
registers, flags, and step counts with the original x86 loops.

From the repository root, with the development requirements installed:

```sh
python3 tools/lift_game.py
python3 tools/generate_imports.py
git diff -- engine/generated
```

The inputs are `assets/cold-memory.bin`, `assets/entry-points.json`, and
`assets/resolved-imports.json`. Three additional instruction entry points were
observed in the original runtime (`430042`, `460000`, `460001`). They are explicit
seeds because a scan of the cold image's data pointers alone does not discover them.
This reproduces the established 126,124-instruction translation without a warm
process capture.

Make instruction changes in `tools/lift_game.py`, regenerate, then run the native
integration and differential tests followed by a browser build/playthrough.
`coverage.json` lists decoded instructions that still trap; it is not a statement
that those instructions are reachable during normal gameplay.
