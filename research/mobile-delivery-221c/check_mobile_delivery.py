#!/usr/bin/env python3
"""Exercise actual AppModel/API delivery with private synthetic transport boundaries."""
import argparse
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ios/scripts"))
from notification_test_support import write_notification_sources

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--swiftc", required=True)
p.add_argument("--core-build", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
cases = p.add_mutually_exclusive_group()
cases.add_argument("--composer-owner-only", action="store_true")
cases.add_argument("--load-boundaries", action="store_true")
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output([a.swiftc, "--version"], text=True)
print(version, flush=True)
sources = []
for path in [Path("ios/Argo/Model") / (name + ".swift") for name in (
    "AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"
)] + [Path("ios/Argo/Support/L10n.swift")]:
    text = path.read_text()
    if "Swift version 6.0." in version:
        text = re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", text)
    target = a.output / path.name
    target.write_text(text)
    sources.append(str(target))
sources += list(map(str, write_notification_sources(a.output, lambda path: Path(path).read_text())))

# Execute the real view callbacks with the actual model. Only framework storage,
# native text and selector types use the existing Linux boundary doubles.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_composer import block
owner = Path("ios/Argo/Model/ComposerInputOwner.swift")
chat = Path("ios/Argo/Views/Chat/ChatView.swift").read_text()
page = Path("ios/Argo/Views/Chat/ComposerPageEditor.swift").read_text()
prompt = Path("ios/Argo/Views/Chat/PromptComposer.swift").read_text()
typed = Path("ios/Argo/DesignSystem/TypedText.swift").read_text()
platform = Path("research/return-event/LinuxPlatform.swift").read_text()
platform = platform.split("@MainActor @Observable final class ConversationState")[0]
native = "@MainActor final class ComposerTextView: UITextView, UITextPasteDelegate {" + block(typed, "final class ComposerTextView:") + "}"
coordinator = "@MainActor final class Coordinator: NSObject, UITextViewDelegate {" + block(typed, "final class Coordinator:") + "}"
native = re.sub(r"#selector\((\w+)\)", r'"\1"', native).replace("@objc private func", "func")
renew = block(chat, "private func renewInputOwner()")
renew = renew.replace("destinationIsCurrent: {", "destinationIsCurrent: { [self] in").replace("foreground: {", "foreground: { [self] in")
send = block(chat, "send: {")
methods = "\n".join("func " + name + "() {" + block(page, "private func " + name + "()") + "}" for name in ("sendOnce", "commitTyped", "finish"))
methods = methods.replace("get: {", "get: { [self] in").replace("set: {", "set: { [self] in")

def callback(source, marker):
    return block(source, marker).split(" in", 1)[1]

prompt_methods = "\n".join("func " + name + "() {" + block(prompt, "private func " + name + "()") + "}" for name in ("inputRevoked", "pageDismissed"))
page_events = "\n".join((
    "func appear() {" + block(page, ".onAppear") + "}",
    "func disappear() {" + block(page, ".onDisappear") + "}",
    "func inputChanged(_ current: Bool) {" + callback(page, ".onChange(of: input.canCommit)") + "}",
))
# Check that the callbacks compiled below are still connected to the actual
# sheet/owner changes. SwiftUI presentation itself requires the iOS SDK.
assert "if !current { inputRevoked() }" in callback(prompt, ".onChange(of: input.canCommit)")
assert "onDismiss: pageDismissed" in prompt
assert "renewInputOwner: renewInputOwner" in chat
assert "pagePresentation.owner == nil ? $selection : $parkedSelection" in prompt
assert ".id(inputOwner.id)" in chat
assert ".onChange(of: model.acceptsComposerInput)" in chat

callbacks = r"""
@MainActor struct Binding<Value> {
    let get: () -> Value
    let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
@MainActor enum TypedText {
    static var shown: String?
    static var commits = 0
    static func commitFocused(into text: Binding<String>) {
        commits += 1
        if let shown { text.wrappedValue = shown }
    }
}
@MainActor final class ComposerChatProbe {
    let state: ConversationState
    let model: AppModel
    var inputOwner: ComposerInputOwner?
    init(state: ConversationState, model: AppModel) { self.state = state; self.model = model }
    func renewInputOwner() { RENEW }
    func sendAction(for inputOwner: ComposerInputOwner) -> () -> Void {
        let target = inputOwner.state
        return { [self] in SEND }
    }
}
@MainActor final class ComposerPageProbe {
    let input: ComposerInputOwner
    var canSend = true
    var focused = true
    var cursor: NSRange? = NSRange(location: 4, length: 2)
    var selection: NSRange?
    var submission = ComposerSubmission()
    let send: () -> Void
    var done: () -> Void = {}
    init(input: ComposerInputOwner, send: @escaping () -> Void) { self.input = input; self.send = send }
    METHODS
    PAGE_EVENTS
}
@MainActor final class ComposerPromptProbe {
    let input: ComposerInputOwner
    let model: AppModel
    let pagePresentation = SeenPresentation()
    var focused = true
    var sentFromPage = false
    let renewInputOwner: () -> Void
    init(input: ComposerInputOwner, model: AppModel, renew: @escaping () -> Void) {
        self.input = input; self.model = model; self.renewInputOwner = renew
    }
    PROMPT_CALLBACKS
}
""".replace("RENEW", renew).replace("SEND", send).replace("METHODS", methods).replace("PAGE_EVENTS", page_events).replace("PROMPT_CALLBACKS", prompt_methods)
callback_path = a.output / "ComposerCallbacks.swift"
callback_path.write_text("\n".join([platform, native, coordinator, callbacks]))
sources += [str(owner), str(callback_path)]

core = a.core_build / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
assert objects, "Build actual ArgoMobileKit before running this check"
binary = a.output / "mobile-delivery-check"
fixture = "LoadBoundaryCheck" if a.load_boundaries else "MobileDeliveryCheck"
subprocess.run([a.swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2", "-I", str(core / "Modules"),
                *map(str, objects), *sources, f"research/mobile-delivery-221c/{fixture}.swift", "-o", str(binary)], check=True)
runs = [["initial-nil-to-valid"], ["stable-refresh"]] if a.load_boundaries else [["--composer-owner-only"] if a.composer_owner_only else []]
for arguments in runs:
    subprocess.run([str(binary.resolve()), *arguments], check=True)
