#!/usr/bin/env python3
"""Run real AppModel/PhoneNotifications against synthetic OS and network boundaries."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--swiftc", required=True)
parser.add_argument("--core-build", type=Path, required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--source-ref")
parser.add_argument("--expect-original-bug", action="store_true")
parser.add_argument("--include-auth-combination", action="store_true",
                    help="Also check re-pairing after old credentials are revoked at token/open boundaries")
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output([args.swiftc, "--version"], text=True)
print(version, flush=True)

def source(path):
    if args.source_ref:
        return subprocess.check_output(["git", "show", f"{args.source_ref}:{path}"], text=True)
    return Path(path).read_text()

paths = [f"ios/Argo/Model/{name}.swift" for name in (
    "AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"
)] + ["ios/Argo/Support/L10n.swift", "ios/Argo/Notifications/PhoneNotifications.swift"]
sources = []
for path in paths:
    text = source(path)
    if "Swift version 6.0." in version:
        text = re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", text)
    if path.endswith("PhoneNotifications.swift"):
        # Only native platform/persistence/config boundaries are substituted.
        text = text.replace("import UIKit\n", "").replace("import UserNotifications\n", "")
        text = text.replace("UserDefaults.standard", "NotificationTestPlatform.defaults")
        text = text.replace("Bundle.main", "NotificationTestPlatform.bundle")
    target = args.output / Path(path).name
    target.write_text(text)
    sources.append(target)

# Execute the actual ArgoApp callback wiring; baseline keeps its original binding.
wiring = re.findall(r"^\s*model\?\.(?:unregisterNotifications|prepareNotificationsForPairing|restoreNotificationsAfterPairing) = .*", source("ios/Argo/ArgoApp.swift"), re.M)
assert wiring, "ArgoApp notification wiring not found"
target = args.output / "NotificationWiring.swift"
preparation = "prepareNotificationsForPairing" if any("prepareNotificationsForPairing" in line for line in wiring) else "unregisterNotifications"
probe = f"""
    let originalPrepare = model?.{preparation}
    model?.{preparation} = {{ id in
        NotificationTestPlatform.preparationBegan = true
        try await originalPrepare?(id)
    }}
"""
target.write_text("@MainActor func bindNotifications(to target: AppModel) {\n    let model: AppModel? = target\n" + "\n".join(wiring) + probe + "\n}\n")
sources.append(target)
core = args.core_build / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
assert objects, "Build ArgoMobileKit first"
binary = args.output / "repair-notifications-check"
subprocess.run([args.swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2",
                "-I", str(core / "Modules"), *map(str, objects), *map(str, sources),
                "research/repair-notifications/NotificationPlatform.swift",
                "research/repair-notifications/RepairNotificationsCheck.swift", "-o", str(binary)], check=True)
cases = ["success", "expired", "cancelPair", "cancelDelete", "disabled", "restoreOffline",
         "expiredRestoreOffline", "deleteOffline", "latePUT", "changedHost", "changedToken", "overlappingPair", "forget"]
if args.include_auth_combination:
    cases += ["revokedTokenRepair", "revokedOpenRepair", "revokedExpired"]
failures = set()
outputs = {}
for case in cases:
    result = subprocess.run([str(binary.resolve()), case], capture_output=True, text=True, timeout=20)
    print(result.stdout + result.stderr, end="", flush=True)
    outputs[case] = result
    if result.returncode:
        failures.add(case)
if args.expect_original_bug:
    expected = {"success", "expired", "cancelPair", "cancelDelete", "restoreOffline", "expiredRestoreOffline", "latePUT", "changedHost", "changedToken", "overlappingPair"}
    assert failures == expected, (failures, expected)
    for case in expected:
        result = outputs[case]
        assert result.returncode == 1, (case, result.returncode)
        marker = "STALE RECEIPT" if case in {"latePUT", "changedHost", "changedToken"} else "ALERT INTENT LOST"
        assert marker in result.stdout, (case, result.stdout)
    print("PASS: baseline exited 1 in exactly 10 expected cases; intent/receipt assertions matched; 3 controls passed")
else:
    print(f"Repair notifications: {len(cases) - len(failures)}/{len(cases)} passed")
    if failures:
        sys.exit(1)
