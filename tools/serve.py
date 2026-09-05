"""Serve editable web files with a built or downloaded WebAssembly runtime."""

import argparse
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "build/site"
PUBLISHED = "https://veritr1x.github.io/lemonade-tycoon-web/"
RUNTIME = ("lemonade.js", "lemonade.wasm", "lemonade.data")
from build_web import SHELL_FILES as SHELL, HOST_API

BUILT = False


def download_runtime():
    """Use the published build for HTML/CSS/JS work without installing emsdk."""
    SITE.mkdir(parents=True, exist_ok=True)
    with urlopen(PUBLISHED + "build.json", timeout=30) as response:
        manifest = json.load(response)
    if manifest.get("host_api", 1) != HOST_API:
        raise SystemExit(
            "The published runtime does not match this checkout. "
            "Activate Emscripten and run tools/build.py --port web."
        )
    for name in RUNTIME:
        with urlopen(PUBLISHED + name, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != manifest["files"][name]:
            raise SystemExit(
                f"Checksum mismatch: {name}. Retry after deployment finishes."
            )
        (SITE / name).write_bytes(data)
        print(f"Downloaded {name}", flush=True)
    (SITE / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")


class Handler(SimpleHTTPRequestHandler):
    """Expose only the app files, never the source tree or local build inputs."""

    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".webmanifest": "application/manifest+json",
    }

    def translate_path(self, path):
        name = unquote(urlsplit(path).path).lstrip("/") or "index.html"
        if name in SHELL:
            return str((SITE if BUILT else ROOT / "ports/web") / name)
        if name == "sw.js" and BUILT:
            return str(SITE / name)
        if name in (*RUNTIME, "build.json"):
            return str(SITE / name)
        return str(SITE / "__not_found__")

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download-runtime", action="store_true")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument(
        "--built",
        action="store_true",
        help="Serve the complete build, including offline installation",
    )
    args = parser.parse_args()
    BUILT = args.built
    if args.download_runtime:
        download_runtime()
    if not all((SITE / name).is_file() for name in RUNTIME):
        parser.error("Build with tools/build.py or pass --download-runtime first.")
    mode = "complete offline build" if BUILT else "edit ports/web/ and reload"
    print(f"Open http://127.0.0.1:{args.port}/ — {mode}", flush=True)
    try:
        ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    except KeyboardInterrupt:
        pass
