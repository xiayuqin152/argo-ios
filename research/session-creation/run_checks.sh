#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_dir"
package=ios/Packages/ArgoMobileKit
swift build --package-path "$package" --jobs 2
module_dir=$(swift build --package-path "$package" --show-bin-path)
probe="$module_dir/creation-lifecycle-check"
swiftc -swift-version 6 -parse-as-library -j 2 -I "$module_dir/Modules" \
  "$module_dir"/ArgoMobileKit.build/*.swift.o \
  ios/Argo/Model/NewSessionState.swift \
  research/session-creation/CreationCheckSupport.swift \
  research/session-creation/CreationLifecycleCheck.swift \
  -o "$probe"
"$probe"
