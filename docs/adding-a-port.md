# Adding a port

Keep the original game and compatibility code in `engine/`, reproducible inputs in
`assets/`, and platform-specific code in `ports/<name>/`. Reuse the engine and assets
instead of copying them into each port. Generated game code remains under
`engine/generated/`; only its generator should change it.

1. Add a host adapter and a short README under `ports/<name>/`. Implement the frame,
   dialog, text input, URL, audio, storage, and lifecycle boundaries declared in
   `engine/platform.h` and `engine/audio.h`. Use `engine/game.h` for copied HUD state
   and `engine/save.h` for compatible backups and transfers. Native hosts can follow the iOS worker
   thread model; event-loop hosts can follow the web adapter's bounded stepping.
2. Add `tools/build_<name>.py` and register it in `BUILDERS` in `tools/build.py`.
   Contributors should build with `python3 tools/build.py --port <name>` and inspect
   options with `--port-help`. Resolve paths relative to the checkout and write all
   products and caches under ignored `build/` directories.
3. Add a CI build using the same command on a suitable runner. Run shared tests for
   engine changes and build every supported port. Publishing is a separate step:
   only the web workflow currently uploads and deploys an artifact.
4. Document toolchain requirements, launch steps, save locations, input behavior,
   and the checks actually performed. Exercise startup, gameplay, text entry,
   sound, background/resume, persistence, and clean exit/restart on the target.

Changes needed by multiple hosts belong in the shared engine. Keep host-specific
APIs and UI in the port directory. Signing identities, provisioning profiles, device
identifiers, and build products must remain local; do not add them to source or CI logs.
