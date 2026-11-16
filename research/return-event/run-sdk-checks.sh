#!/usr/bin/env bash
# For the lead's existing GitHub macOS job, after XcodeGen setup. Not run on Linux.
# All generated project/build files live in a fresh task-specific temporary dir.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf '%s\n' "Usage: bash research/return-event/run-sdk-checks.sh DESTINATION|auto [build-for-testing|test]" >&2
  exit 2
fi
destination=$1
action=${2:-build-for-testing}
case "$action" in build-for-testing|test) ;; *) printf '%s\n' 'Unsupported action' >&2; exit 2 ;; esac
repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/argo-return-sdk.XXXXXX")
log_dir=${RETURN_EVENT_LOG_DIR:-$scratch}
result_bundle=${RETURN_EVENT_XCRESULT:-$scratch/ReturnEventTests.xcresult}
mkdir -p "$scratch/Host" "$scratch/Tests" "$log_dir" "$(dirname "$result_bundle")"
cp "$repo_dir/ios/Argo/DesignSystem/TypedText.swift" "$scratch/Host/TypedText.swift"
cp "$repo_dir/research/return-event/UIKitInputTests.swift" "$scratch/Tests/UIKitInputTests.swift"
cat > "$scratch/Host/HostApp.swift" <<'SWIFT'
import SwiftUI
@main struct ReturnEventHostApp: App {
    var body: some Scene { WindowGroup { Color.clear } }
}
SWIFT
cat > "$scratch/project.yml" <<'YAML'
name: ReturnEventHost
settings:
  base:
    SWIFT_VERSION: "6.0"
    GENERATE_INFOPLIST_FILE: YES
    CODE_SIGNING_ALLOWED: NO
targets:
  ReturnEventHost:
    type: application
    platform: iOS
    deploymentTarget: "26.0"
    sources: [Host]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.argo.return-event-host
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
  ReturnEventTests:
    type: bundle.unit-test
    platform: iOS
    deploymentTarget: "26.0"
    sources: [Tests]
    dependencies:
      - target: ReturnEventHost
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.argo.return-event-tests
schemes:
  ReturnEventHost:
    build:
      targets:
        ReturnEventHost: all
        ReturnEventTests: [test]
    test:
      targets: [ReturnEventTests]
YAML
xcodegen generate --no-env --spec "$scratch/project.yml" --project "$scratch" --project-root "$scratch"
if [[ $destination == auto ]]; then
  command -v xcrun >/dev/null
  xcrun simctl list runtimes -j > "$log_dir/uikit-simctl-runtimes.json"
  xcrun simctl list devices available -j > "$log_dir/uikit-simctl-devices.json"
  udid=$(python3 - "$log_dir/uikit-simctl-devices.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    data = json.load(source)
candidates = []
for runtime, devices in data.get("devices", {}).items():
    version = tuple(int(part) for part in runtime.rsplit("iOS-", 1)[-1].split("-")) if "iOS-" in runtime else (0,)
    for device in devices:
        if device.get("isAvailable") is True and device.get("name", "").startswith("iPhone"):
            candidates.append((version, device.get("state") == "Booted", device["name"],
                               device["udid"], runtime, device.get("state", "unknown")))
if not candidates:
    raise SystemExit("No available iPhone Simulator was found; see uikit-simctl-devices.json")
_, _, name, udid, runtime, state = max(candidates, key=lambda item: (item[0], item[1], item[2]))
print(f"Selected {name} ({runtime}, {state}, {udid})", file=sys.stderr)
print(udid)
PY
)
  destination="platform=iOS Simulator,id=$udid"
fi
printf 'SDK harness artifacts: %s\n' "$scratch"
printf 'Simulator destination: %s\n' "$destination"
xcodebuild -jobs 2 -parallel-testing-enabled NO -project "$scratch/ReturnEventHost.xcodeproj" \
  -scheme ReturnEventHost -configuration Debug -destination "$destination" \
  -derivedDataPath "$scratch/build" -resultBundlePath "$result_bundle" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "$action" 2>&1 | tee "$log_dir/uikit-xcodebuild.log"
