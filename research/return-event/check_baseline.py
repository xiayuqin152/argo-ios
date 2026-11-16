#!/usr/bin/env python3
"""Require INPUT-01 from the real baseline callbacks, preserving the failing exit."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = "27ba9f50b5e840a320919e6960942de625cf02bf"


def block(source, marker):
    start = source.index("{", source.index(marker))
    end, depth = start + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    args = parser.parse_args()
    source = subprocess.check_output(
        ["git", "show", f"{BASE}:ios/Argo/DesignSystem/TypedText.swift"], cwd=ROOT, text=True)
    # Same callback harness as the existing composer check, with an actual LF paste
    # as its input. Only UIKit/SwiftUI framework types are replaced on Linux.
    declarations = source[source.index("    static let enabledKey"):source.index("    /// What a hardware Return")]
    edit = block(source, ".onChange(of: text)").split("old, new in", 1)[1]
    swift = r'''
import Foundation
enum ReturnSends {
DECLARATIONS
}
enum TypedText { static var composingFocused: Bool { false } }
final class UITextView { var text = "待确认\n" }
enum FirstResponder { static var current: Any? { nil } }
struct Replay {
    var enabled = true, paused = false, breakAllowed = false
    var text = "待确认\n"
    var sends = 0
    static var lineBreakModifierHeld: Bool { false }
    mutating func act() { sends += 1 }
    mutating func edit(_ old: String, _ new: String) {
EDIT
    }
}
var replay = Replay()
replay.edit("待确认", "待确认\n")
print("baseline=BASE sends=\(replay.sends) draft=\(String(reflecting: replay.text))")
if replay.sends != 0 || replay.text != "待确认\n" {
    print("FAIL INPUT-01: LF paste sends the old draft and removes the newline")
    exit(17)
}
print("PASS: LF paste remains a draft edit")
'''.replace("DECLARATIONS", declarations).replace("EDIT", edit).replace("BASE", BASE)
    with tempfile.TemporaryDirectory(prefix="argo-return-baseline-") as directory:
        path = Path(directory)
        (path / "main.swift").write_text(swift)
        subprocess.run([args.swiftc, "-j", "2", str(path / "main.swift"), "-o", str(path / "check")], check=True)
        result = subprocess.run([str(path / "check")], capture_output=True, text=True)
        print(result.stdout, end="")
        print(f"baseline_exit={result.returncode} expected=17")
        assert result.returncode == 17 and "sends=1" in result.stdout and "FAIL INPUT-01" in result.stdout
        print("PASS: expected baseline failure reproduced from production code")


if __name__ == "__main__":
    main()
