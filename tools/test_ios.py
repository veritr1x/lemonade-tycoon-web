"""Run iOS host geometry checks on macOS without booting a simulator."""

from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build/tests/ios-layout"
OUTPUT.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(
    [
        "xcrun",
        "clang",
        "-std=c11",
        "-fsanitize=address,undefined",
        str(ROOT / "ports/ios/tests/layout.c"),
        "-framework",
        "CoreGraphics",
        "-o",
        str(OUTPUT),
    ],
    check=True,
)
subprocess.run([str(OUTPUT)], check=True)
