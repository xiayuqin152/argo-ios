#!/usr/bin/env python3
"""Replay the production composer's callbacks with synthetic Linux input events.

The callbacks/policies are extracted verbatim. Only Apple framework types are
stubbed; this checks the state transitions, not UIKit event delivery or layout.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index("{", source.index(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    parser.add_argument("--revision", help="Read a Git revision instead of the working tree")
    parser.add_argument("--expect", choices=("pass", "baseline-option-bugs", "rejected-ime-latch"), default="pass",
                        help="Require exactly the named baseline Option failures or rejected IME-latch regression")
    args = parser.parse_args()

    def read(path):
        if args.revision:
            return subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    source = read("ios/Argo/DesignSystem/TypedText.swift")
    policy = block(source, "enum ReturnSends {")
    key = block(source, ".onKeyPress(.return, phases: .down)").split("press in", 1)[1]
    edit = block(source, ".onChange(of: text)").split("old, new in", 1)[1]
    held_name = re.search(r"!Self\.(\w+) else", edit).group(1)
    held = block(source, f"private static var {held_name}:")
    act = block(source, "private func act()")
    owner = read("ios/Argo/Model/ComposerInputOwner.swift")
    # Swift 6.0.3 predates type-level nonisolated; no policy or callback changes.
    owner = owner.replace("nonisolated struct ComposerSubmission", "struct ComposerSubmission")
    swift = r'''
import Foundation
import Observation

struct EventModifiers: OptionSet {
    let rawValue: Int
    static let shift = Self(rawValue: 1)
    static let option = Self(rawValue: 2)
    static let command = Self(rawValue: 4)
    static let control = Self(rawValue: 8)
    static let capsLock = Self(rawValue: 16)
    static let numericPad = Self(rawValue: 32)
}
enum KeyCode { case leftShift, rightShift, leftAlt, rightAlt }
struct KeyState { let isPressed = true }
struct KeyboardInput {
    var held: Set<KeyCode> = []
    func button(forKeyCode key: KeyCode) -> KeyState? { held.contains(key) ? KeyState() : nil }
}
@MainActor struct GCKeyboard {
    var keyboardInput: KeyboardInput?
    static var coalesced: GCKeyboard?
}
@MainActor enum TypedText { static var composingFocused = false }
@MainActor final class UITextView { var text = "" }
@MainActor enum FirstResponder { static var current: Any? }
struct KeyPress { var modifiers: EventModifiers }
enum KeyResult { case ignored, handled }
@MainActor @Observable final class ConversationState { var draft = "" }
'''
    swift += owner
    swift += "\nenum ReturnSends {" + policy + "}\n"
    swift += r'''
@MainActor struct Replay {
    var enabled = true
    var paused = false
    var canSend = true
    var gate: (() -> Void)?
    var breakAllowed = false
    var text = "草稿"
    var sends = 0
    var send: () -> Void { { } }
'''
    # Replace only the external effect with a counter; retain dispatch policy.
    swift += "mutating func act() {" + act.replace("send()", "sends += 1") + "}\n"
    swift += "mutating func key(_ press: KeyPress) -> KeyResult {" + key + "}\n"
    swift += "mutating func edit(_ old: String, _ new: String) {" + edit + "}\n"
    swift += f"static var {held_name}: Bool {{" + held + "}\n}\n"
    swift += r'''
@main struct Checks {
    @MainActor static func main() {
        var failures: Set<String> = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.insert(name) }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        let field = UITextView()
        FirstResponder.current = field
        func insertedBreak(_ replay: inout Replay) {
            let old = replay.text
            let new = old + "\n"
            replay.text = new
            field.text = new
            replay.edit(old, new)
        }
        var ime = Replay()
        TypedText.composingFocused = true
        check(ime.key(KeyPress(modifiers: [])) == .ignored && ime.sends == 0,
              "IME Return belongs to the text input without sending")
        // Confirmation can clear marked state without changing the visible String.
        // No edit callback occurs until the user's later, separate fallback Return.
        TypedText.composingFocused = false
        insertedBreak(&ime)
        check(ime.sends == 1 && ime.text == "草稿",
              "A later fallback Return sends after unchanged-string IME confirmation")
        var captured = Replay()
        TypedText.composingFocused = true
        _ = captured.key(KeyPress(modifiers: []))
        TypedText.composingFocused = false
        check(captured.key(KeyPress(modifiers: [])) == .handled && captured.sends == 1,
              "A later captured Return sends after unchanged-string IME confirmation")
        for key in [KeyCode.leftAlt, .rightAlt, .leftShift, .rightShift] {
            GCKeyboard.coalesced = GCKeyboard(keyboardInput: KeyboardInput(held: [key]))
            var replay = Replay()
            insertedBreak(&replay)
            check(replay.sends == 0 && replay.text == "草稿\n", "Missed key event preserves newline with \(key)")
        }
        GCKeyboard.coalesced = nil
        for modifiers: EventModifiers in [[], .capsLock, .numericPad] {
            var replay = Replay()
            check(replay.key(KeyPress(modifiers: modifiers)) == .handled && replay.sends == 1,
                  "Plain Return sends once with modifiers \(modifiers.rawValue)")
        }
        for modifiers: EventModifiers in [.shift, .option] {
            var replay = Replay()
            check(replay.key(KeyPress(modifiers: modifiers)) == .ignored, "Modified Return passes through")
            insertedBreak(&replay)
            check(replay.sends == 0 && replay.text == "草稿\n", "Modified Return newline is retained")
        }
        var normal = Replay()
        insertedBreak(&normal)
        check(normal.sends == 1 && normal.text == "草稿", "Software Return sends without its newline")
        var disabled = Replay(enabled: false)
        insertedBreak(&disabled)
        check(disabled.sends == 0 && disabled.text == "草稿\n", "Default setting retains newline")
        var paused = Replay(paused: true)
        insertedBreak(&paused)
        check(paused.sends == 0 && paused.text == "草稿\n", "Unfocused or covered composer never sends")
        var unavailable = Replay(canSend: false)
        insertedBreak(&unavailable)
        check(unavailable.sends == 0 && unavailable.text == "草稿", "Unavailable send consumes Return without sending")
        TypedText.composingFocused = true
        var marked = Replay()
        insertedBreak(&marked)
        check(marked.sends == 0 && marked.text == "草稿\n", "Software Return while marked never sends")
        var confirmed = Replay()
        _ = confirmed.key(KeyPress(modifiers: []))
        TypedText.composingFocused = false
        confirmed.text = "已确认"
        confirmed.edit("草稿", "已确认")
        insertedBreak(&confirmed)
        check(confirmed.sends == 1, "A later Return sends after a non-newline IME confirmation")
        check(!ReturnSends.breakTyped(from: "草稿", to: "草稿\n第二行"), "Multiline text insertion never sends")
        let a = ConversationState(), b = ConversationState()
        var current = true, foreground = true
        let owner = ComposerInputOwner(state: a, destinationIsCurrent: { current }, foreground: { foreground })
        owner.text = "会话 A"
        check(a.draft == "会话 A" && b.draft.isEmpty, "Draft edits belong to the captured conversation")
        foreground = false
        owner.text = "late callback"
        check(a.draft == "会话 A", "Inactive input rejects delayed edits")
        owner.commit("已确认组合输入")
        check(a.draft == "已确认组合输入", "Lifecycle commit retains original destination while inactive")
        current = false
        foreground = true
        owner.text = "wrong destination"
        owner.commit("wrong destination")
        check(a.draft == "已确认组合输入" && b.draft.isEmpty, "Conversation switch rejects old-owner writes")
        current = true
        owner.invalidate()
        owner.text = "revoked"
        owner.commit("revoked")
        check(a.draft == "已确认组合输入", "Revoked owner rejects edits and commits")
        var submission = ComposerSubmission()
        check(!submission.claim(allowed: false) && submission.claim(allowed: true) && !submission.claim(allowed: true),
              "Page submission is admitted once")
        print("CHECKS=\(checks) FAILURES=\(failures.count)")
        let expectedFailures: Set<String> = EXPECTED_FAILURES
        exit(failures == expectedFailures ? 0 : 1)
    }
}
'''
    expected = {
        "pass": [],
        "baseline-option-bugs": ["Missed key event preserves newline with leftAlt",
                                 "Missed key event preserves newline with rightAlt"],
        "rejected-ime-latch": ["A later fallback Return sends after unchanged-string IME confirmation"],
    }[args.expect]
    swift = swift.replace("EXPECTED_FAILURES", json.dumps(expected))
    with tempfile.TemporaryDirectory(prefix="composer-", dir=ROOT / "research") as directory:
        path = Path(directory)
        (path / "replay.swift").write_text(swift)
        subprocess.run([args.swiftc, "-swift-version", "6", "-j", "2", "-parse-as-library", str(path / "replay.swift"),
                        "-o", str(path / "replay")], check=True)
        subprocess.run([str(path / "replay")], check=True)


if __name__ == "__main__":
    main()
