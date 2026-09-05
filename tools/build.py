"""Build a port: python3 tools/build.py --port web|ios [port options]."""

import argparse
from pathlib import Path
import subprocess
import sys

# Register new ports here; each builder owns its toolchain and ignored output.
BUILDERS = {"web": "build_web.py", "ios": "build_ios.py"}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", choices=BUILDERS, default="web")
    parser.add_argument(
        "--port-help", action="store_true", help="Show the selected builder's options"
    )
    args, options = parser.parse_known_args()
    builder = Path(__file__).resolve().with_name(BUILDERS[args.port])
    raise SystemExit(
        subprocess.call(
            [sys.executable, str(builder), *(["--help"] if args.port_help else options)]
        )
    )
