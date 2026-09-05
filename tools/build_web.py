"""Build the static browser app. Requires Emscripten 6.0.9 on PATH."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VERSION = "6.0.9"
HOST_API = 4
SHELL_FILES = (
    "index.html",
    "app.js",
    "style.css",
    "saves.js",
    "layout.js",
    "splitter.js",
    "offline.js",
    "preferences.js",
    "manifest.webmanifest",
    "icon-192.png",
    "icon-512.png",
)
RUNTIME_FILES = ("lemonade.js", "lemonade.wasm", "lemonade.data")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build(jobs):
    os.chdir(ROOT)
    emcc = os.environ.get("EMCC") or shutil.which("emcc")
    if not emcc:
        raise SystemExit(
            "emcc not found. Activate Emscripten 6.0.9; see CONTRIBUTING.md."
        )
    compiler = subprocess.check_output([emcc, "--version"], text=True)
    if VERSION not in compiler.splitlines()[0]:
        raise SystemExit(
            f"Expected Emscripten {VERSION}; found {compiler.splitlines()[0]}"
        )

    output = ROOT / "build/site"
    objects = ROOT / "build/wasm"
    output.mkdir(parents=True, exist_ok=True)
    objects.mkdir(parents=True, exist_ok=True)
    sources = [
        Path("engine/runtime.c"),
        Path("engine/audio.c"),
        Path("engine/save.c"),
        Path("engine/lifecycle.c"),
        *sorted(Path("engine/generated").glob("*.c")),
        # host.c includes platform.c so it can drive the shared engine lifecycle.
        Path("ports/web/host.c"),
    ]
    flags = ["-O2", "-DLEMON_WEB", "-Wno-tautological-constant-out-of-range-compare"]
    headers = b"".join(p.read_bytes() for p in sorted(Path("engine").rglob("*.h")))
    headers += Path("engine/platform.c").read_bytes()
    cache_inputs = headers + compiler.encode() + repr(flags).encode()

    def compile_source(source):
        obj = objects / (source.stem + ".o")
        stamp = obj.with_suffix(".sha256")
        digest = hashlib.sha256(source.read_bytes() + cache_inputs).hexdigest()
        if obj.exists() and stamp.exists() and stamp.read_text() == digest:
            return obj
        result = subprocess.run(
            [emcc, *flags, "-std=gnu11", "-c", str(source), "-o", str(obj)],
            capture_output=True,
            text=True,
        )
        if result.returncode:
            raise RuntimeError(f"{source}\n{result.stderr}")
        stamp.write_text(digest)
        return obj

    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        built = []
        for index, obj in enumerate(pool.map(compile_source, sources), 1):
            built.append(obj)
            if index % 10 == 0:
                print(f"Compiled {index}/{len(sources)} units", flush=True)

    exports = [
        "_lemon_web_start",
        "_lemon_web_step",
        "_lemon_web_active",
        "_lemon_web_flush_input",
        "_lemon_web_audio",
        "_lemon_web_read_state",
        "_lemon_web_export",
        "_lemon_web_import",
        "_lemon_request_quit",
        "_lemon_audio_levels",
        "_lemon_touch",
        "_lemon_key",
    ]
    subprocess.run(
        [
            emcc,
            *flags,
            *map(str, built),
            "--no-entry",
            # Unbounded single-caller inlining creates a 14 MB function Chrome rejects.
            "-sBINARYEN_EXTRA_PASSES=--one-caller-inline-max-function-size=1000",
            "-sMODULARIZE=1",
            "-sEXPORT_ES6=1",
            "-sEXPORT_NAME=createLemonade",
            "-sENVIRONMENT=web",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sINITIAL_MEMORY=335544320",
            "-sSTACK_SIZE=2097152",
            "-sEXPORTED_FUNCTIONS=" + json.dumps(exports),
            '-sEXPORTED_RUNTIME_METHODS=["FS","IDBFS"]',
            "-lidbfs.js",
            "--preload-file",
            "assets/cold-memory.bin@/cold-memory.bin",
            "--preload-file",
            "assets/Lemonade.RB@/Game/Lemonade.RB",
            "-o",
            str(output / "lemonade.js"),
        ],
        check=True,
    )

    # Validate before uploading a site that browsers cannot instantiate.
    node = os.environ.get("EMSDK_NODE") or shutil.which("node")
    if not node:
        raise SystemExit("Node is needed to validate the module (included in emsdk).")
    subprocess.run(
        [
            node,
            "-e",
            "const fs=require('fs');new WebAssembly.Module(fs.readFileSync(process.argv[1]));"
            "console.log('WebAssembly validation passed');",
            str(output / "lemonade.wasm"),
        ],
        check=True,
    )
    for name in SHELL_FILES:
        shutil.copy2(ROOT / "ports/web" / name, output / name)
    (output / ".nojekyll").touch()
    # Contributors can download these verified runtime files for shell-only edits.
    revision = subprocess.run(
        ["git", "rev-parse", "HEAD"], capture_output=True, text=True
    )
    manifest = {
        "host_api": HOST_API,
        "revision": revision.stdout.strip() or "local",
        "emscripten": VERSION,
        "files": {name: sha256(output / name) for name in RUNTIME_FILES},
    }
    (output / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    worker = (ROOT / "ports/web/sw.js").read_text()
    files = {name: sha256(output / name) for name in (*SHELL_FILES, *RUNTIME_FILES)}
    version = hashlib.sha256(
        (worker + json.dumps(files, sort_keys=True)).encode()
    ).hexdigest()[:20]
    precache = {"version": version, "files": files}
    (output / "sw.js").write_text(
        worker.replace("/* @build */ null", json.dumps(precache))
    )
    print(f"Built {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=min(6, os.cpu_count() or 2))
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    build(args.jobs)
