# Lemonade Tycoon Ports

[Play in your browser](https://veritr1x.github.io/lemonade-tycoon-web/) ·
[Contribute](CONTRIBUTING.md) · [How it works](docs/architecture.md)

The original Lemonade Tycoon game on the web and iOS, sharing one translated C
engine and the original game resources. Each port supplies graphics, sound, input,
and storage through a small host adapter.

| Port | Build                               | Run                                                            |
| ---- | ----------------------------------- | -------------------------------------------------------------- |
| Web  | `python3 tools/build.py --port web` | [Play online](https://veritr1x.github.io/lemonade-tycoon-web/) |
| iOS  | `python3 tools/build.py --port ios` | [Simulator and device setup](ports/ios/README.md)              |

See [Contributing](CONTRIBUTING.md) for toolchain requirements. The default build
remains the web port. The repository URL stays the same so existing Pages links work.

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

Open <http://127.0.0.1:8000/>, edit files in `ports/web/`, and reload. The command downloads
the published runtime once into the ignored `build/` directory. Later runs can
omit `--download-runtime`. For C changes, see the [build instructions](CONTRIBUTING.md#build-the-engine).

## Find your way around

| Path                | Purpose                                                        |
| ------------------- | -------------------------------------------------------------- |
| `ports/web/`        | Page, styling, input, audio scheduling, and browser storage    |
| `ports/web/host.c`  | Bridge between the game engine and browser callbacks           |
| `ports/ios/`        | UIKit display/input, AVAudioEngine, and app lifecycle          |
| `engine/`           | Handwritten runtime, Windows API adapter, PCM mixer, and tests |
| `engine/generated/` | Generated original-game code; change its generator instead     |
| `tools/`            | Build, local server, tests, and code generation                |
| `assets/`           | Game resources and reproducible translation inputs             |

GitHub Actions tests the shared runtime and builds the web and iOS ports. Changes
merged to `main` publish the web port to GitHub Pages. iOS CI verifies a simulator
build without uploading an app or IPA. Build products and SDKs stay out of Git history.
To add another platform, follow [Adding a port](docs/adding-a-port.md).

## Status

Chrome has been exercised through career creation, a complete day, save/reload,
audio output, text editing, fullscreen, and quit/restart. Mobile layouts and field
focus have been checked with viewport emulation; physical iPhone Safari keyboard
presentation still needs device testing. Long campaigns and historical online
services are not covered by these checks. Known runtime limitations are in the
[architecture notes](docs/architecture.md#current-boundaries).

Original game credits and notices remain in the game. See [NOTICE](NOTICE) for
the distinction between port implementation and original game material.
