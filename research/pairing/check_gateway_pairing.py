#!/usr/bin/env python3
"""Run the actual GatewayPairing implementation against a held stream on Linux.

This checks cancellation and credential handling without Network.framework,
an iOS SDK, a camera, or a live gateway. Run the package's core tests first.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("ios/Packages/ArgoMobileKit/Sources/ArgoMobileKit/LoomKitShared/GatewayConnection.swift")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref", help="Read GatewayPairing from this Git revision")
    parser.add_argument("--expect-cancellation-bug", action="store_true",
                        help="Require the baseline's six cancellation assertions to fail")
    args = parser.parse_args()
    if args.expect_cancellation_bug and not args.source_ref:
        parser.error("--expect-cancellation-bug requires --source-ref")
    swiftc = os.environ.get("SWIFTC") or shutil.which("swiftc")
    if not swiftc:
        raise SystemExit("Set SWIFTC to the existing Linux Swift compiler")
    source = (
        subprocess.check_output(["git", "show", f"{args.source_ref}:{SOURCE}"], cwd=ROOT, text=True)
        if args.source_ref else (ROOT / SOURCE).read_text()
    )
    implementation = source.split("public enum GatewayPairing {", 1)[1].rsplit("#endif", 1)[0]
    build = ROOT / "ios/Packages/ArgoMobileKit/.build/debug"
    objects = sorted((build / "ArgoMobileKit.build").glob("*.swift.o"))
    if not objects:
        raise SystemExit("Run swift test --package-path ios/Packages/ArgoMobileKit --jobs 2 first")
    with tempfile.TemporaryDirectory(prefix="gateway-probe-", dir=ROOT / "research/pairing") as temporary:
        directory = Path(temporary)
        generated = directory / "Probe.swift"
        generated.write_text(
            (ROOT / "research/pairing/GatewayPairingProbe.swift").read_text()
            + "\npublic enum GatewayPairing {" + implementation
        )
        executable = directory / "probe"
        subprocess.run([
            swiftc, "-swift-version", "6", "-j", "2", "-parse-as-library", "-I", str(build / "Modules"),
            str(generated), *map(str, objects), "-o", str(executable),
        ], check=True, cwd=ROOT)
        if args.expect_cancellation_bug:
            result = subprocess.run([str(executable)], cwd=ROOT, text=True, capture_output=True)
            print(result.stdout, end="")
            print(result.stderr, end="", file=sys.stderr)
            expected = {
                "FAIL: cancel finishes while the peer is still silent",
                "FAIL: cancel closes the pending handshake",
                "FAIL: a late credential cannot complete a cancelled pairing",
                "FAIL: already cancelled pairing finishes without contacting the peer",
                "FAIL: already cancelled pairing never opens a stream",
                "FAIL: already cancelled pairing reports CancellationError",
            }
            actual = {line for line in result.stdout.splitlines() if line.startswith("FAIL:")}
            if result.returncode != 1 or actual != expected:
                raise SystemExit("Baseline did not reproduce exactly the expected cancellation failures")
            print("EXPECTED: baseline reproduced all six cancellation failures (probe exit 1)")
        else:
            subprocess.run([str(executable)], check=True, cwd=ROOT)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
