#!/usr/bin/env python3
"""Check real notification permission/registration state with controlled OS/HTTP.

No APNs, network traffic or real notification preferences are used. --core-build
is an existing ArgoMobileKit build containing Modules and ArgoMobileKit.build.
--source-ref selects production notification code; test boundaries stay current.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from notification_test_support import notification_sources

ROOT = Path(__file__).resolve().parents[2]
CASES = ["deniedDuringPUT", "staleAuthorized", "staleDenied", "enableStaleAuthorized",
         "grantThenDenied", "deniedThenGranted", "deniedDuringDELETE", "undeterminedDuringDELETE", "deniedOffline", "coldReceipt",
         "currentAuthorized", "currentProvisional", "currentEphemeral", "enableCurrent", "disableThenRefresh",
         "enableSupersededAllowed", "enableSupersededDenied", "enableThenDisable", "enableThenForget", "enableThenPairing",
         "firstGrantNewerFirstAllowedToken", "firstGrantNewerFirstDeniedToken", "firstGrantNewerLastAllowedToken", "firstGrantNewerLastDeniedToken",
         "firstGrantNewerFirstAllowedNoToken", "firstGrantNewerFirstDeniedNoToken", "firstGrantNewerLastAllowedNoToken", "firstGrantNewerLastDeniedNoToken",
         "waitingThenDisable", "waitingThenForget", "waitingThenPairing", "waitingThenReplacement",
         "promptErrorOwnership", "promptReplacement", "promptThenDisable", "promptThenForget", "promptThenPairing", "cancelledEnableSnapshot"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    parser.add_argument("--core-build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-ref")
    parser.add_argument("--only", nargs="+", choices=CASES, default=CASES)
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if not compiler:
        parser.error("Swift compiler not found")
    core = args.core_build.resolve()
    objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
    if not objects or not (core / "Modules/ArgoMobileKit.swiftmodule").exists():
        parser.error("--core-build needs Modules/ArgoMobileKit.swiftmodule and ArgoMobileKit.build/*.o")
    output = args.output.resolve()
    for name in ["sources", "runtime", "tmp", "cache"]:
        (output / name).mkdir(parents=True, exist_ok=True)
    inputs = {}

    def source(path):
        if args.source_ref and path == "ios/Argo/Notifications/PhoneNotifications.swift":
            value = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{args.source_ref}:{path}"], text=True)
        else:
            value = (ROOT / path).read_text()
        inputs[path] = hashlib.sha256(value.encode()).hexdigest()
        return value

    def save(name, value):
        path = output / "sources" / name
        path.write_text(value)
        return path

    sources = notification_sources(source, save)
    sources.append(save("NotificationAuthorizationCheck.swift", source("ios/Argo/Verification/NotificationAuthorizationCheck.swift")))
    binary = output / "notification-authorization-check"
    command = [os.path.abspath(compiler), "-swift-version", "6", "-parse-as-library", "-j", "2",
               "-module-cache-path", str(output / "cache/modules"), "-I", str(core / "Modules"),
               *map(str, objects), *map(str, sources), "-o", str(binary)]
    env = dict(os.environ, TMPDIR=str(output / "tmp"), XDG_CACHE_HOME=str(output / "cache"),
               CLANG_MODULE_CACHE_PATH=str(output / "cache/clang"))
    with (output / "compile.log").open("w") as log:
        subprocess.run(command, cwd=output / "runtime", env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    for case in args.only:
        result = subprocess.run([str(binary), case], cwd=output / "runtime", env=env, capture_output=True, text=True, timeout=20)
        text = result.stdout + result.stderr
        (output / (case + ".log")).write_text(text)
        ok = result.returncode == 0 and f"PASS {case}" in text and "FAIL " not in text
        results.append(dict(case=case, exit=result.returncode, ok=ok))
        print(text, end="", flush=True)
    manifest = dict(source_ref=args.source_ref, inputs=inputs, compile_command=command, compile_exit=0, results=results)
    (output / "results.json").write_text(json.dumps(manifest, indent=2) + "\n")
    passed = sum(r["ok"] for r in results)
    print(f"Notification authorization: {passed}/{len(results)} passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
