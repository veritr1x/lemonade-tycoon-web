"""Build the original game's AOT native code and UIKit adapter for iOS."""

import argparse
import concurrent.futures
import datetime
import fnmatch
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--device", action="store_true", help="Build for a physical iPhone/iPad"
)
parser.add_argument(
    "--profile", type=Path, help="Development provisioning profile for a device build"
)
parser.add_argument(
    "--identity", help="SHA-1 of the Apple Development signing identity"
)
parser.add_argument("--udid", help="Verify that the profile includes this device")
parser.add_argument("--bundle-id", default="local.lemonade.tycoon")
parser.add_argument("--jobs", type=int, default=min(6, os.cpu_count() or 2))
parser.add_argument(
    "--smoke-test",
    action="store_true",
    help="Build a separate simulator app that checks host interactions",
)
args = parser.parse_args()
if args.jobs < 1:
    parser.error("--jobs must be positive")
if args.profile:
    args.profile = args.profile.expanduser().resolve()
os.chdir(ROOT)
bundle_id = args.bundle_id
if args.smoke_test:
    if args.device:
        parser.error("--smoke-test is simulator-only")
    bundle_id += ".smoketest"
entitlements = None
# Signing inputs stay on the contributor's machine; only generated output uses them.
if args.device:
    if not args.profile or not args.identity:
        parser.error("--device requires --profile and --identity")
    profile = plistlib.loads(
        subprocess.check_output(["security", "cms", "-D", "-i", str(args.profile)])
    )
    if profile["ExpirationDate"] <= datetime.datetime.now(
        datetime.timezone.utc
    ).replace(tzinfo=None):
        parser.error("Provisioning profile has expired")
    if args.identity.upper() not in [
        hashlib.sha1(c).hexdigest().upper() for c in profile["DeveloperCertificates"]
    ]:
        parser.error("Signing identity is not in the provisioning profile")
    if args.udid and args.udid not in profile.get("ProvisionedDevices", []):
        parser.error("Device is not in the provisioning profile")
    allowed = profile["Entitlements"]
    team = allowed["com.apple.developer.team-identifier"]
    app_id = profile["ApplicationIdentifierPrefix"][0] + "." + bundle_id
    if not fnmatch.fnmatchcase(app_id, allowed["application-identifier"]):
        parser.error("Provisioning profile does not allow this bundle identifier")
    entitlements = {
        "application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "get-task-allow": allowed.get("get-task-allow", False),
    }
    if any(
        fnmatch.fnmatchcase(app_id, g)
        for g in allowed.get("keychain-access-groups", [])
    ):
        entitlements["keychain-access-groups"] = [app_id]
sdk_name = "iphoneos" if args.device else "iphonesimulator"
sdk = subprocess.check_output(
    ["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True
).strip()
compiler = subprocess.check_output(
    ["xcrun", "--sdk", sdk_name, "--find", "clang"], text=True
).strip()
compiler_version = subprocess.check_output([compiler, "--version"])
output = ROOT / "build" / ("ios-device" if args.device else "ios-simulator")
if args.smoke_test:
    output = ROOT / "build/ios-smoke"
objects = output / "objects"
objects.mkdir(parents=True, exist_ok=True)
app = output / "LemonadeTycoon.app"
app.mkdir(exist_ok=True)
sources = [
    Path("engine/runtime.c"),
    *sorted(Path("engine/generated").glob("*.c")),
    Path("engine/platform.c"),
    Path("engine/audio.c"),
    Path("engine/lifecycle.c"),
    Path("ports/ios/main.m"),
    Path("ports/ios/GameView.m"),
]
flags = [
    "-target",
    "arm64-apple-ios17.0" + ("" if args.device else "-simulator"),
    "-isysroot",
    sdk,
    "-O1",
    "-DLEMON_IOS",
    "-Wno-tautological-constant-out-of-range-compare",
]
if args.smoke_test:
    sources.append(Path("ports/ios/tests/smoke.m"))
    flags.append("-DLEMON_UI_SMOKE_TEST")
headers = b"".join(p.read_bytes() for p in sorted(Path("engine").rglob("*.h")))
headers += b"".join(p.read_bytes() for p in sorted(Path("ports/ios").glob("*.h")))


def compile(source):
    """Reuse an object only when its source, headers, compiler, and flags match."""
    obj = objects / (source.stem + ".o")
    stamp = obj.with_suffix(".sha256")
    digest = hashlib.sha256(
        source.read_bytes() + headers + compiler_version + str(flags).encode()
    ).hexdigest()
    if obj.exists() and stamp.exists() and stamp.read_text() == digest:
        return
    extra = ["-fobjc-arc"] if source.suffix == ".m" else ["-std=gnu11"]
    r = subprocess.run(
        [compiler, *flags, *extra, "-c", str(source), "-o", str(obj)],
        capture_output=True,
        text=True,
    )
    if r.returncode:
        raise RuntimeError(str(source) + "\n" + r.stderr)
    stamp.write_text(digest)


with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
    for i, _ in enumerate(pool.map(compile, sources), 1):
        if i % 10 == 0:
            print(f"Compiled {i}/{len(sources)} iOS units", flush=True)
subprocess.run(
    [
        compiler,
        *flags,
        *[str(objects / (s.stem + ".o")) for s in sources],
        "-framework",
        "UIKit",
        "-framework",
        "Foundation",
        "-framework",
        "CoreGraphics",
        "-framework",
        "QuartzCore",
        "-framework",
        "AVFoundation",
        "-o",
        str(app / "LemonadeTycoon"),
    ],
    check=True,
)
# Construct a minimal app bundle directly; no generated Xcode project is needed.
icon_info = output / "asset-info.plist"
subprocess.run(
    [
        "xcrun",
        "actool",
        "ports/ios/Assets.xcassets",
        "--compile",
        str(app),
        "--platform",
        sdk_name,
        "--minimum-deployment-target",
        "17.0",
        "--target-device",
        "iphone",
        "--target-device",
        "ipad",
        "--app-icon",
        "AppIcon",
        "--output-partial-info-plist",
        str(icon_info),
    ],
    check=True,
)
info = dict(
    CFBundleDevelopmentRegion="en",
    CFBundleIdentifier=bundle_id,
    CFBundleName="Lemonade Tycoon",
    CFBundleDisplayName="Lemonade Tycoon",
    CFBundleExecutable="LemonadeTycoon",
    CFBundlePackageType="APPL",
    CFBundleVersion="7",
    CFBundleShortVersionString="0.1",
    MinimumOSVersion="17.0",
    UIDeviceFamily=[1, 2],
    LSRequiresIPhoneOS=True,
    UILaunchScreen={},
    UISupportedInterfaceOrientations=[
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    ],
    UIStatusBarHidden=True,
    CFBundleSupportedPlatforms=["iPhoneOS" if args.device else "iPhoneSimulator"],
)
info.update(plistlib.loads(icon_info.read_bytes()))
(app / "Info.plist").write_bytes(plistlib.dumps(info))
(app / "Game").mkdir(exist_ok=True)
shutil.copy2("assets/cold-memory.bin", app / "cold-memory.bin")
shutil.copy2("assets/Lemonade.RB", app / "Game" / "Lemonade.RB")
if args.device:
    shutil.copy2(args.profile, app / "embedded.mobileprovision")
    entitlements_path = output / "entitlements.plist"
    entitlements_path.write_bytes(plistlib.dumps(entitlements))
    subprocess.run(
        [
            "codesign",
            "--force",
            "--sign",
            args.identity,
            "--entitlements",
            str(entitlements_path),
            "--generate-entitlement-der",
            str(app),
        ],
        check=True,
    )
else:
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print(app.resolve())
