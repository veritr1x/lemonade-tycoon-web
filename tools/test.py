"""Run focused C tests; --integration also executes the original translated game."""

import argparse
import concurrent.futures
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/tests"


def run_test(compiler, name, sources, sanitize=True):
    flags = [
        "-std=gnu11",
        "-O1",
        "-g",
        "-Wno-tautological-constant-out-of-range-compare",
    ]
    if sanitize:
        flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    executable = OUTPUT / name
    subprocess.run(
        [
            compiler,
            *flags,
            *map(str, sources),
            "-lm",
            "-pthread",
            "-o",
            str(executable),
        ],
        check=True,
    )
    result = subprocess.run(
        [str(executable)], capture_output=True, text=True, timeout=90
    )
    log = result.stdout + result.stderr
    (OUTPUT / (name + ".log")).write_text(log)
    if result.returncode:
        print(log)
        raise SystemExit(f"FAIL: {name} ({result.returncode})")
    print(
        next(
            (line for line in result.stdout.splitlines() if line.startswith("PASS:")),
            f"PASS: {name}",
        )
    )


def integration(compiler):
    objects = ROOT / "build/native"
    objects.mkdir(parents=True, exist_ok=True)
    sources = [
        Path("engine/runtime.c"),
        Path("engine/audio.c"),
        Path("engine/save.c"),
        Path("engine/lifecycle.c"),
        *sorted(Path("engine/generated").glob("*.c")),
    ]
    headers = b"".join(p.read_bytes() for p in sorted(Path("engine").rglob("*.h")))
    compiler_version = subprocess.check_output([compiler, "--version"])

    def compile_source(source):
        obj = objects / (source.stem + ".o")
        stamp = obj.with_suffix(".sha256")
        digest = hashlib.sha256(
            source.read_bytes() + headers + compiler_version
        ).hexdigest()
        if not (obj.exists() and stamp.exists() and stamp.read_text() == digest):
            subprocess.run(
                [
                    compiler,
                    "-std=gnu11",
                    "-O1",
                    "-fPIC",
                    "-Wno-tautological-constant-out-of-range-compare",
                    "-c",
                    str(source),
                    "-o",
                    str(obj),
                ],
                check=True,
            )
            stamp.write_text(digest)
        return obj

    print("Compiling the translated runtime for integration tests…", flush=True)
    with concurrent.futures.ThreadPoolExecutor(
        max_workers=min(6, os.cpu_count() or 2)
    ) as pool:
        built = list(pool.map(compile_source, sources))
    for name in ("configuration", "urls", "restart", "gameplay"):
        run_test(
            compiler, name, [Path(f"engine/tests/{name}.c"), *built], sanitize=False
        )
    # This shared library is also the native side of the optional Unicorn oracle.
    mac = platform.system() == "Darwin"
    library = objects / ("liblemonade.dylib" if mac else "liblemonade.so")
    subprocess.run(
        [
            compiler,
            "-dynamiclib" if mac else "-shared",
            "-O1",
            "engine/tests/renderer_oracle.c",
            *map(str, built),
            "-lm",
            "-pthread",
            "-o",
            str(library),
        ],
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--integration", action="store_true")
    args = parser.parse_args()
    os.chdir(ROOT)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    compiler = os.environ.get("CC") or shutil.which("clang")
    if not compiler:
        parser.error("Install Clang or set CC to a compatible C compiler.")
    cases = {
        "renderer": [],
        "audio": ["engine/audio.c"],
        "lifecycle": ["engine/lifecycle.c"],
        "runtime_exit": ["engine/runtime.c"],
        "platform": ["engine/audio.c", "engine/lifecycle.c", "engine/save.c"],
        "save": ["engine/save.c"],
    }
    for name, sources in cases.items():
        run_test(compiler, name, [f"engine/tests/{name}.c", *sources])
    if args.integration:
        integration(compiler)
