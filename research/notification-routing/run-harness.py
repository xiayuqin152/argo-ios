#!/usr/bin/env python3
"""Execute production notification sequencing with Linux system API doubles."""
import argparse
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--swift-bin", required=True)
parser.add_argument("--source", type=Path, default=Path("ios/Argo/Notifications/PhoneNotifications.swift"))
parser.add_argument("--root-source", type=Path, default=Path("ios/Argo/Views/RootView.swift"))
parser.add_argument("--output", type=Path, default=Path("research/notification-routing/harness-build"))
parser.add_argument("--expect-baseline-failures", action="store_true")
parser.add_argument("--snapshot-at-completion", action="store_true")
parser.add_argument("--cleanup-before-receipt", action="store_true")
parser.add_argument("--expect-pre-receipt-failures", action="store_true")
args = parser.parse_args()
if args.expect_pre_receipt_failures and not args.cleanup_before_receipt:
    parser.error("--expect-pre-receipt-failures requires --cleanup-before-receipt")
root = Path(__file__).resolve().parents[2]
args.output.mkdir(parents=True, exist_ok=True)
# The only source changes remove imports unavailable on Linux. Business logic,
# state, access control and actor isolation are compiled directly from production.
source = args.source.read_text().replace("import UIKit\n", "").replace("import UserNotifications\n", "")
phone = args.output / "PhoneNotifications.swift"
phone.write_text(source)
# Compile RootView's notification handoff verbatim, with view/presentation
# dependencies replaced by simple objects. No guard or routing logic is copied
# into the test fixture, so changing the production handoff changes this check.
root_source = args.root_source.read_text()
start = root_source.index("    private func openNotification() {")
end = root_source.index("\n    private var compactHosts:", start)
handoff = args.output / "RootNotificationHarness.swift"
handoff.write_text("""import ArgoMobileKit
@MainActor final class RootNotificationHarness {
    let model: AppModel
    let notifications = PhoneNotifications.shared
    let hostsBinding = HarnessBinding()
    let pairingPresentation = HarnessPresentation()
    let settingsPresentation = HarnessPresentation()
    var hostPairingShown = false
    init(model: AppModel) { self.model = model }
    func drive() { openNotification() }
""" + root_source[start:end] + "\n}\n")
core = root / "research/notification-routing/core-build/debug"
compiler = Path(args.swift_bin) / "swiftc"
exe = args.output / "notification-harness"
command = [str(compiler), "-swift-version", "6", "-parse-as-library", "-j", "2",
           "-I", str(core / "Modules"), str(root / "research/notification-routing/SystemDoubles.swift"),
           str(phone), str(handoff), str(root / "research/notification-routing/Harness.swift"),
           *map(str, (core / "ArgoMobileKit.build").glob("*.swift.o")), "-o", str(exe)]
compiled = subprocess.run(command)
if compiled.returncode:
    raise SystemExit(compiled.returncode)
run = [str(exe.resolve()), str((args.output / "fixture").resolve())]
if args.snapshot_at_completion: run.append("--snapshot-at-completion")
if args.cleanup_before_receipt: run.append("--cleanup-before-receipt")
result = subprocess.run(run, capture_output=True, text=True, timeout=60)
print(result.stdout, end="")
print(result.stderr, end="")
if args.expect_pre_receipt_failures:
    expected = [
        "pre-receipt token rotation preserves delivered notification",
        "pre-receipt token rotation preserves pending notification",
        "delayed token cleanup preserves replacement delivered notification",
        "delayed token cleanup preserves replacement pending notification",
        "pre-receipt re-enable preserves delivered notification",
        "pre-receipt re-enable preserves pending notification",
        "delayed DELETE cleanup preserves re-enabled delivered notification",
        "delayed DELETE cleanup preserves re-enabled pending notification",
        "pre-receipt permission restoration preserves delivered notification",
        "pre-receipt permission restoration preserves pending notification",
        "restored permission preserves current delivered notification",
        "restored permission preserves current pending notification",
    ]
    actual = [line.removeprefix("FAIL: ") for line in result.stdout.splitlines() if line.startswith("FAIL: ")]
    if result.returncode != 1 or actual != expected or "FAILURES: 12\n" not in result.stdout:
        raise SystemExit("Pre-receipt ordering did not reproduce exactly the expected failures")
    print("PASS: expected exit 1, six pre-receipt losses and six later losses verified; 20 other assertions passed")
elif args.expect_baseline_failures:
    expected = [
        "host-file read failure preserves a cold-launch tap",
        "successful host-file retry opens the original notification exactly once",
        "delayed token cleanup preserves replacement delivered notification",
        "delayed token cleanup preserves replacement pending notification",
        "delayed DELETE cleanup preserves re-enabled delivered notification",
        "delayed DELETE cleanup preserves re-enabled pending notification",
        "restored permission preserves current delivered notification",
        "restored permission preserves current pending notification",
    ]
    actual = [line.removeprefix("FAIL: ") for line in result.stdout.splitlines() if line.startswith("FAIL: ")]
    if result.returncode != 1 or actual != expected or "FAILURES: 8\n" not in result.stdout:
        raise SystemExit("Baseline did not reproduce exactly the expected regressions")
    print("PASS: expected baseline exit 1 and all eight regression assertions verified")
else:
    raise SystemExit(result.returncode)
