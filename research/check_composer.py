#!/usr/bin/env python3
"""Compile the real native event handlers/coordinator against Linux framework doubles.

This executes production methods, not a second implementation of their policy.
UIKit delivery, layout and IME integration require the separate hosted SDK checks.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index("{", source.index(marker))
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    parser.add_argument("--negative-control", action="store_true",
                        help="Require regressions when the production replacement-origin guard is removed in a temporary copy")
    args = parser.parse_args()
    source = (ROOT / "ios/Argo/DesignSystem/TypedText.swift").read_text()
    native = "@MainActor final class ComposerTextView: UITextView, UITextPasteDelegate {" + block(source, "final class ComposerTextView:") + "}"
    coordinator = "@MainActor final class Coordinator: NSObject, UITextViewDelegate {" + block(source, "final class Coordinator:") + "}"
    # Objective-C selector syntax is unavailable on Linux; selectors are names in
    # the double. All event, focus, draft, selection and send method bodies remain.
    native = re.sub(r"#selector\((\w+)\)", r'"\1"', native).replace("@objc private func", "func")
    if args.negative_control:
        assert ", !replacing," in native
        native = native.replace(", !replacing,", ",", 1)
    owner = (ROOT / "ios/Argo/Model/ComposerInputOwner.swift").read_text()
    support = (ROOT / "research/return-event/LinuxPlatform.swift").read_text()
    checks = (ROOT / "research/return-event/InputChecks.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="argo-return-event-") as directory:
        path = Path(directory)
        (path / "replay.swift").write_text("\n".join([support, owner, native, coordinator, checks]))
        subprocess.run([args.swiftc, "-swift-version", "6", "-j", "2", "-parse-as-library",
                        str(path / "replay.swift"), "-o", str(path / "replay")], check=True)
        result = subprocess.run([str(path / "replay")], capture_output=True, text=True)
        print(result.stdout, end="")
        print(result.stderr, end="")
        if args.negative_control:
            assert result.returncode == 1 and 'FAIL Paste/Drop preserves exact inserted text "\\n"' in result.stdout
            print("PASS: removing the actual replacement-origin guard fails the LF paste regression (exit=1)")
        else:
            result.check_returncode()


if __name__ == "__main__":
    main()
