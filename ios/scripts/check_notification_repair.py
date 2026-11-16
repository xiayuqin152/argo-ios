#!/usr/bin/env python3
"""Compile real notification navigation and pairing with synthetic HTTP/OS boundaries.

--core-build points to a built ArgoMobileKit directory containing Modules and
ArgoMobileKit.build. All generated sources, caches and runtime files use --output.
The fixture sends no network traffic and uses no real notification preferences.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CASES = ["pushB", "sameHostRun", "userB", "forget", "repair", "reconnect", "pairFailed", "pairRollback", "newerRoute", "missingAgent"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    parser.add_argument("--core-build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-ref", help="Read production sources from this Git revision")
    parser.add_argument("--only", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--expect-repair-failure", action="store_true",
                        help="Assert the original repair failure, including raw exit 1")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if not compiler:
        parser.error("Swift compiler not found; supply --swiftc explicitly")
    compiler = os.path.abspath(compiler)
    core = args.core_build.resolve()
    objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
    if not objects or not (core / "Modules/ArgoMobileKit.swiftmodule").exists():
        parser.error("--core-build needs Modules/ArgoMobileKit.swiftmodule and ArgoMobileKit.build/*.o")
    if args.expect_repair_failure and args.only != ["repair"]:
        parser.error("--expect-repair-failure requires --only repair")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for folder in ["sources", "runtime", "tmp", "cache"]:
        (output / folder).mkdir(exist_ok=True)
    env = dict(os.environ, TMPDIR=str(output / "tmp"), XDG_CACHE_HOME=str(output / "cache"),
               CLANG_MODULE_CACHE_PATH=str(output / "cache/clang"))
    version = subprocess.check_output([compiler, "--version"], text=True)

    def source(path):
        if args.source_ref:
            return subprocess.check_output(["git", "-C", str(ROOT), "show", f"{args.source_ref}:{path}"], text=True)
        return (ROOT / path).read_text()

    def save(name, text):
        path = output / "sources" / name
        if "Swift version 6.0." in version:
            text = re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", text)
        path.write_text(text)
        return path

    sources = [save(name + ".swift", source(f"ios/Argo/Model/{name}.swift")) for name in
               ["AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"]]
    sources.append(save("L10n.swift", source("ios/Argo/Support/L10n.swift")))
    phone = source("ios/Argo/Notifications/PhoneNotifications.swift")
    phone = phone.replace("import UIKit\n", "").replace("import UserNotifications\n", "")
    phone = phone.replace("UserDefaults.standard", "NotificationTestPlatform.defaults").replace("Bundle.main", "NotificationTestPlatform.bundle")
    sources.append(save("PhoneNotifications.swift", phone))
    # Reuse the published in-memory OS adapter; no registration logic is replaced.
    sources.append(save("NotificationPlatform.swift", source("research/repair-notifications/NotificationPlatform.swift")))
    root_view = source("ios/Argo/Views/RootView.swift")
    start = root_view.index("    private func openNotification() {")
    end = root_view.index("\n    private var compactHosts:", start)
    sources.append(save("RootNotificationHarness.swift", """import ArgoMobileKit
@MainActor final class HarnessBinding { var wrappedValue = true }
@MainActor final class RootNotificationHarness {
    let model: AppModel
    let notifications = PhoneNotifications.shared
    let hostsBinding = HarnessBinding()
    let pairingPresentation = SeenPresentation()
    let settingsPresentation = SeenPresentation()
    var hostPairingShown = true
    init(model: AppModel) { self.model = model }
    func drive() { openNotification() }
""" + root_view[start:end] + "\n}\n"))
    wiring = re.findall(r"^\s*model\?\.(?:unregisterNotifications|prepareNotificationsForPairing|restoreNotificationsAfterPairing) = .*",
                        source("ios/Argo/ArgoApp.swift"), re.M)
    if len(wiring) != 3:
        raise RuntimeError("Expected all three production notification callbacks")
    sources.append(save("NotificationWiring.swift", "@MainActor func bindNotifications(to target: AppModel) {\n"
                        "    let model: AppModel? = target\n" + "\n".join(wiring) + "\n}\n"))
    sources.append(save("NotificationRepairCheck.swift", (ROOT / "ios/Argo/Verification/NotificationRepairCheck.swift").read_text()))
    binary = output / "notification-repair-check"
    command = [compiler, "-swift-version", "6", "-parse-as-library", "-j", "2", "-module-cache-path", str(output / "cache/modules"),
               "-I", str(core / "Modules"), *map(str, objects), *map(str, sources), "-o", str(binary)]
    with (output / "compile.log").open("w") as log:
        subprocess.run(command, cwd=output / "runtime", env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    for case in args.only:
        result = subprocess.run([str(binary), case], cwd=output / "runtime", env=env, capture_output=True, text=True, timeout=30)
        text = result.stdout + result.stderr
        (output / (case + ".log")).write_text(text)
        if args.expect_repair_failure:
            ok = (result.returncode == 1 and
                  "OBSERVED repair: retiredRouteTrusted=false, selectedRun=r2, currentDeviceIsReplacement=true" in text and
                  "FAIL repair: Retired notification navigated after re-pair to replacement credentials" in text)
        else:
            ok = result.returncode == 0 and f"PASS {case}:" in text and "FAIL " not in text
        results.append(dict(case=case, exit=result.returncode, ok=ok))
        print(text, end="", flush=True)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if args.expect_repair_failure:
        print("PASS expected baseline exit 1 and retired-route assertion" if all(r["ok"] for r in results) else "FAIL baseline assertion")
    return 0 if all(r["ok"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
