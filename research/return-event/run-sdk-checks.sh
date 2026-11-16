#!/usr/bin/env bash
# For the lead's existing GitHub macOS job, after XcodeGen setup. Not run on Linux.
# All generated project/build files live in a fresh task-specific temporary dir.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 2 ]]; then
  printf '%s\n' "Usage: bash research/return-event/run-sdk-checks.sh DESTINATION [build-for-testing|test]" >&2
  exit 2
fi
destination=$1
action=${2:-build-for-testing}
case "$action" in build-for-testing|test) ;; *) printf '%s\n' 'Unsupported action' >&2; exit 2 ;; esac
repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/argo-return-sdk.XXXXXX")
mkdir -p "$scratch/Host" "$scratch/Tests"
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
printf 'SDK harness artifacts: %s\n' "$scratch"
xcodebuild -jobs 2 -parallel-testing-enabled NO -project "$scratch/ReturnEventHost.xcodeproj" \
  -scheme ReturnEventHost -configuration Debug -destination "$destination" \
  -derivedDataPath "$scratch/build" -resultBundlePath "$scratch/ReturnEventTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO "$action" 2>&1 | tee "$scratch/xcodebuild.log"
