#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
usage() {
  printf '%s\n' 'Usage: bash research/run-transcript-regression.sh [--swift-bin DIR]' \
    'Use --swift-bin or ARGO_TRANSCRIPT_SWIFT_BIN for a Swift toolchain directory.' \
    'Otherwise swift and swiftc are resolved from PATH.'
}
swift_bin="${ARGO_TRANSCRIPT_SWIFT_BIN:-}"
while (($#)); do
  case "$1" in
    --swift-bin)
      if [[ $# -lt 2 || -z "$2" ]]; then
        printf '%s\n' 'error: --swift-bin requires a toolchain directory' >&2
        exit 2
      fi
      swift_bin="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
swift="${swift_bin:+$swift_bin/}swift"
swiftc="${swift_bin:+$swift_bin/}swiftc"
for tool in "$swift" "$swiftc"; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'error: Swift tool not found: %s; use --swift-bin, ARGO_TRANSCRIPT_SWIFT_BIN or PATH\n' "$tool" >&2
    exit 2
  fi
done
package=ios/Packages/ArgoMobileKit
"$swift" build --package-path "$package" --jobs 2
bin_path=$("$swift" build --package-path "$package" --show-bin-path)
notification_dir=$(mktemp -d "${TMPDIR:-/tmp}/argo-transcript-notifications.XXXXXX")
trap 'rm -rf -- "$notification_dir"' EXIT
python3 - "$notification_dir" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, "ios/scripts")
from notification_test_support import write_notification_sources
write_notification_sources(Path(sys.argv[1]), lambda path: Path(path).read_text())
PY
"$swiftc" -swift-version 6 -j 2 -parse-as-library -I "$bin_path/Modules" \
  ios/Argo/Model/AgentSession.swift ios/Argo/Model/AppModel.swift \
  ios/Argo/Model/AttachmentDraft.swift ios/Argo/Model/ConversationState.swift \
  ios/Argo/Model/ModelRecoveryState.swift ios/Argo/Model/NewSessionState.swift \
  ios/Argo/Support/L10n.swift "$package/Tests/ArgoMobileKitTests/Support.swift" \
  "$notification_dir/PhoneNotifications.swift" "$notification_dir/NotificationPlatform.swift" \
  research/TranscriptRegression.swift "$bin_path"/ArgoMobileKit.build/*.swift.o \
  -o research/transcript-regression
research/transcript-regression
