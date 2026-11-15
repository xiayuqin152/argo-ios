#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=${1:-}
if [ "$MODE" != "" ] && [ "$MODE" != "--check" ]; then
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 2
fi

command -v xcodegen >/dev/null 2>&1 || {
    printf 'XcodeGen is required; see ios/README.md. No project files were changed.\n' >&2
    exit 1
}
command -v python3 >/dev/null 2>&1 || {
    printf 'python3 is required for project validation.\n' >&2
    exit 1
}

if [ "$MODE" = "--check" ]; then
    python3 "$ROOT/scripts/check_project.py"
    command -v diff >/dev/null 2>&1 || {
        printf 'diff is required for --check.\n' >&2
        exit 1
    }
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/argo-ios-project.XXXXXX")
    trap 'rm -rf "$TMP"' EXIT HUP INT TERM
    cp -R "$ROOT/Argo" "$TMP/Argo"
    mkdir -p "$TMP/Packages" "$TMP/ThirdParty"
    cp -R "$ROOT/Packages/ArgoMobileKit" "$TMP/Packages/ArgoMobileKit"
    cp -R "$ROOT/ThirdParty/BeautifulUI" "$TMP/ThirdParty/BeautifulUI"
    cp "$ROOT/project.yml" "$TMP/project.yml"
    (
        cd "$TMP"
        xcodegen generate --no-env --spec project.yml --project . --project-root .
    )
    diff -ru "$ROOT/Argo.xcodeproj" "$TMP/Argo.xcodeproj"
    printf 'OK: saved Xcode project matches project.yml\n'
else
    cd "$ROOT"
    xcodegen generate --no-env --spec project.yml --project . --project-root .
    python3 scripts/check_project.py
fi
