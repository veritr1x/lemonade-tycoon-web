# Lemonade Tycoon Web

[Play in your browser](https://veritr1x.github.io/lemonade-tycoon-web/) ·
[Contribute](CONTRIBUTING.md) · [How it works](docs/architecture.md)

The original Lemonade Tycoon game running in a browser. Its translated C engine
compiles to WebAssembly and draws the original game graphics on a canvas.
The browser provides sound, touch/mouse input, text entry, and local saves.

## Play

Open the link above and press **Play**. Use the game's original menus and controls.
Text fields open the keyboard automatically; tap outside to dismiss it.
The header provides sound and fullscreen controls where supported.

Progress is stored in your browser at the game's normal save points. Clearing
site data removes it. Saves do not sync between devices, browsers, or site addresses.

## Make your first change

For HTML, CSS, or JavaScript work, Python 3 is enough:

```sh
git clone https://github.com/veritr1x/lemonade-tycoon-web.git
cd lemonade-tycoon-web
python3 tools/serve.py --download-runtime
```

Open <http://127.0.0.1:8000/>, edit files in `web/`, and reload. The command downloads
the published runtime once into the ignored `build/` directory. Later runs can
omit `--download-runtime`. For C changes, see the [build instructions](CONTRIBUTING.md#build-the-engine).

## Find your way around

| Path                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `web/`              | Page, styling, input, audio scheduling, and browser storage    |
| `native/web/host.c` | Bridge between the game engine and browser callbacks           |
| `native/`           | Handwritten runtime, Windows API adapter, PCM mixer, and tests |
| `native/generated/` | Generated original-game code; change its generator instead     |
| `tools/`            | Build, local server, tests, and code generation                |
| `assets/`           | Game resources and reproducible translation inputs             |

GitHub Actions tests and builds pull requests. Changes merged to `main` also
publish to GitHub Pages. Build products and SDKs stay out of Git history.

## Status

Chrome has been exercised through career creation, a complete day, save/reload,
audio output, text editing, fullscreen, and quit/restart. Mobile layouts and field
focus have been checked with viewport emulation; physical iPhone Safari keyboard
presentation still needs device testing. Long campaigns and historical online
services are not covered by these checks. Known runtime limitations are in the
[architecture notes](docs/architecture.md#current-boundaries).

Original game credits and notices remain in the game. See [NOTICE](NOTICE) for
the distinction between port implementation and original game material.
