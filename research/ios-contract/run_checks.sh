#!/usr/bin/env bash
set -euo pipefail
repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_dir"
package=ios/Packages/ArgoMobileKit
swift build --package-path "$package" --jobs 2
module_dir=$(swift build --package-path "$package" --show-bin-path)
probe="$module_dir/ios-model-recovery-contract-check"
swiftc -j 2 -I "$module_dir/Modules" \
  "$module_dir"/ArgoMobileKit.build/*.swift.o \
  ios/Argo/Model/ModelRecoveryState.swift \
  research/ios-contract/ModelRecoveryCheckSupport.swift \
  research/ios-contract/WireContractCheck.swift \
  research/ios-contract/ModelRecoveryCheck.swift \
  -o "$probe"
"$probe"
