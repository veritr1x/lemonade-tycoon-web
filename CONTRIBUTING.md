# Contributing

Start with a small change that you can demonstrate in the game. Useful first
areas include browser layout, keyboard behavior, save feedback, and focused tests.
For a bug report, include the browser/device, steps, game mode/day, and any console
error. Describe expected and actual behavior without attaching personal browser data.

## Edit the browser interface

Follow the one-command setup in [README.md](README.md#make-your-first-change).
`web/app.js` is the entry point. Its comments explain canvas scaling, input focus,
sound scheduling, and storage. Changes appear after a page reload.

## Build the engine

Use Python 3.10+ and Emscripten **6.0.9**. Install the SDK once:

```sh
git clone https://github.com/emscripten-core/emsdk.git .tools/emsdk
python3 .tools/emsdk/emsdk.py install 6.0.9
python3 .tools/emsdk/emsdk.py activate 6.0.9
source .tools/emsdk/emsdk_env.sh
python3 tools/build.py
python3 tools/serve.py
```

The source build writes a self-contained static site to `build/site/` and caches
objects in `build/wasm/`. Reduce parallelism with `--jobs 2` on smaller machines.
The game allocates about 320 MiB of initial WebAssembly memory.

## Check your change

With Clang installed:

```sh
python3 tools/test.py                # Fast tests with address/undefined sanitizers
python3 tools/test.py --integration  # Original startup, configuration, URLs, restart
```

After browser changes, try the [manual checklist](docs/testing.md). For engine
changes, build the browser module too; a native C test alone cannot verify WebAssembly.
Tests write diagnostics under `build/tests/` and use disposable save directories.

Optional formatting and translation tools:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
black tools native/tests/differential.py
clang-format -i native/*.c native/*.h native/web/*.c native/tests/*.c
npx --yes prettier@3.9.6 --write web/*.js web/*.css web/*.html '*.md' docs/*.md
```

Do not format or hand-edit `native/generated/`. See its [README](native/generated/README.md)
before changing instruction translation. The optional differential test compares
the translated routines against the original x86 routines using Unicorn:

```sh
python3 tools/test.py --integration
python3 native/tests/differential.py
```

## Submit a pull request

Keep each change focused. Explain the user-visible behavior, relevant implementation
decision, and what you tested. Include a screenshot for layout changes and a small
regression test for a behavior fix when practical. The Pages workflow builds pull
requests without deploying them; only `main` publishes the live game.

Avoid committing SDKs, generated browser builds, test logs, or save files. A clean
checkout must remain buildable using the checked-in inputs and documented commands.
