import SwiftUI
import UIKit
import XCTest
@testable import ReturnEventHost

// Only public getters supply the synthetic result. The test first requires
// UIKit to insert its newline before checking the enabled Return-send path.
@MainActor private final class SyntheticLineBreakPhrase: UIDictationPhrase {
    override var text: String { "\n" }
    override var alternativeInterpretations: [String]? { ["\n", "\r\n"] }
}

/// Hosted iOS tests of the actual UIKit subclass. No network, clipboard or real
/// messages. Calling the paste delegate checks the final native insertion step;
/// end-to-end paste menus, item providers and physical IMEs remain device checks.
@MainActor final class UIKitInputTests: XCTestCase {
    private func withField(_ body: (ComposerTextView) throws -> Void) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller
        let view = ComposerTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        view.acceptsInput = { true }
        view.pasteDelegate = view
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        view.wantsFocus = true
        view.updateFocus()
        XCTAssertTrue(view.isFirstResponder)
        defer { view.resignFirstResponder(); window.isHidden = true }
        try body(view)
    }

    func testLFPasteDropAndReplacementOnlyEdit() throws {
        try withField { view in
            view.sendsOnReturn = true
            var sends = 0
            view.submit = { _ in sends += 1 }
            view.setDraft("待确认")
            let end = view.endOfDocument
            let insertion = try XCTUnwrap(view.textRange(from: end, to: end))
            let pasted = view.textPasteConfigurationSupporting(view, performPasteOf: NSAttributedString(string: "\n"), to: insertion)
            XCTAssertEqual(view.text, "待确认\n")
            XCTAssertEqual(view.text(in: pasted), "\n")
            XCTAssertEqual(view.selectedRange, NSRange(location: 4, length: 0))
            XCTAssertEqual(sends, 0)

            view.setDraft("甲乙丙")
            let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: 1))
            let finish = try XCTUnwrap(view.position(from: start, offset: 1))
            let range = try XCTUnwrap(view.textRange(from: start, to: finish))
            _ = view.textPasteConfigurationSupporting(view, performPasteOf: NSAttributedString(string: "\n"), to: range)
            XCTAssertEqual(view.text, "甲\n丙")
            let caret = try XCTUnwrap(view.selectedTextRange)
            view.replace(caret, withText: "\n")
            XCTAssertEqual(view.text, "甲\n\n丙")
            view.setDraft("\n")
            XCTAssertEqual(view.text, "\n")
            XCTAssertEqual(sends, 0)
        }
    }

    func testKeyboardReturnAndModifiedKeyCommands() throws {
        try withField { view in
            view.sendsOnReturn = true
            var sent: [String] = []
            view.submit = { field in sent.append(field.text); field.setDraft("") }
            view.setDraft("待确认")
            view.insertText("\n")
            XCTAssertEqual(sent, ["待确认"])
            XCTAssertEqual(view.text, "")
            for modifiers in [UIKeyModifierFlags.shift, .alternate, [.shift, .alternate]] {
                let command = try XCTUnwrap(view.keyCommands?.first { $0.modifierFlags == modifiers })
                let action = try XCTUnwrap(command.action)
                XCTAssertTrue(UIApplication.shared.sendAction(action, to: view, from: command, for: nil))
            }
            XCTAssertEqual(view.text, "\n\n\n")
            XCTAssertEqual(sent.count, 1)
            view.sendsOnReturn = false
            view.setDraft("全页草稿")
            view.selectedRange = NSRange(location: 4, length: 0)
            view.insertText("\n")
            XCTAssertEqual(view.text, "全页草稿\n")
            XCTAssertEqual(sent, ["待确认"])
        }
    }

    func testMarkedTextConfirmationDoesNotSubmit() throws {
        try withField { view in
            view.sendsOnReturn = true
            var sends = 0
            view.submit = { _ in sends += 1 }
            view.setMarkedText("候选", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertNotNil(view.markedTextRange)
            view.insertText("\n")
            XCTAssertEqual(sends, 0)
            view.unmarkText()
            view.insertText("\n")
            XCTAssertEqual(sends, 1)
        }
    }

    func testCoordinatorClearsNativeDraftAndRejectsLatePaste() throws {
        try withField { view in
            var draft = "待确认"
            var selection: NSRange?
            var focused = true
            var valid = true
            var sends = 0
            let binding = Binding(get: { draft }, set: { draft = $0 })
            let parent = ComposerTextInput(text: binding,
                                          selection: Binding(get: { selection }, set: { selection = $0 }),
                                          focused: Binding(get: { focused }, set: { focused = $0 }),
                                          returnSends: true, canSend: true, acceptsInput: { valid }) {
                TypedText.commitFocused(into: binding)
                if !draft.isEmpty { sends += 1; draft = "" }
            }
            let coordinator = parent.makeCoordinator()
            view.delegate = coordinator
            view.acceptsInput = { valid }
            view.sendsOnReturn = true
            view.submit = { coordinator.submit($0) }
            coordinator.updateDraft(view)
            view.insertText("\n")
            view.insertText("\n")
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(draft, "")
            XCTAssertEqual(view.text, "")
            valid = false
            let range = try XCTUnwrap(view.selectedTextRange)
            _ = view.textPasteConfigurationSupporting(view, performPasteOf: NSAttributedString(string: "\n"), to: range)
            XCTAssertEqual(draft, "")
            XCTAssertEqual(view.text, "")
            XCTAssertEqual(sends, 1)
        }
    }

    func testBridgeUsesReadingFontAndSixLineLimit() throws {
        let appeared = expectation(description: "ComposerTextInput appeared in its window")
        let input = ComposerTextInput(text: .constant("甲\n乙\n丙\n丁\n戊\n己\n庚"),
                                      selection: .constant(nil), focused: .constant(false),
                                      maximumLines: 6, canSend: true, acceptsInput: { true }, send: {})
            .environment(\.dynamicTypeSize, .accessibility5)
            .onAppear { appeared.fulfill() }
        let controller = UIHostingController(rootView: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 600)
        window.rootViewController = controller
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        window.makeKeyAndVisible()
        wait(for: [appeared], timeout: 5)
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        func find(_ view: UIView) -> ComposerTextView? {
            if let text = view as? ComposerTextView { return text }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let view = try XCTUnwrap(find(controller.view))
        XCTAssertTrue(view.window === window)
        let expected = UIFont.preferredFont(forTextStyle: .body,
                                           compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(view.font?.pointSize, expected.pointSize)
        XCTAssertLessThanOrEqual(view.bounds.height, ceil(expected.lineHeight * 6))
        XCTAssertGreaterThan(view.bounds.height, expected.lineHeight)
        XCTAssertEqual(view.selectedRange, NSRange(location: (view.text as NSString).length, length: 0))
    }

    func testExplicitDictationResultNewlineDoesNotSubmit() throws {
        try withField { view in
            view.sendsOnReturn = true
            var sends = 0
            view.submit = { _ in sends += 1 }
            view.setDraft("seed")
            view.selectedRange = NSRange(location: 4, length: 0)
            view.insertText("\n")
            XCTAssertEqual(sends, 1, "SETUP: direct Return must reach the enabled send branch")
            guard sends == 1 else { return }
            sends = 0

            let input: any UITextInput = view
            let insertResult = try XCTUnwrap(
                input.insertDictationResult,
                "SETUP: UITextView must implement the public dictation-result callback"
            )
            // Validate the payload through native editing before enabling the
            // send interception. Keep UIKit's actual whitespace as the oracle.
            view.sendsOnReturn = false
            view.setDraft("seed")
            view.selectedRange = NSRange(location: 4, length: 0)
            insertResult([SyntheticLineBreakPhrase()])
            let nativeText = try XCTUnwrap(view.text)
            XCTAssertTrue(nativeText.hasPrefix("seed"), "SETUP: dictation must preserve the existing draft")
            XCTAssertTrue(nativeText.contains("\n"), "SETUP: UIKit must actually insert the synthetic newline")
            guard nativeText.hasPrefix("seed"), nativeText.contains("\n") else { return }

            view.sendsOnReturn = true
            view.setDraft("seed")
            view.selectedRange = NSRange(location: 4, length: 0)
            insertResult([SyntheticLineBreakPhrase()])
            XCTAssertEqual(view.text, nativeText, "DICTATION: the result must remain native text with Return sends enabled")
            XCTAssertEqual(sends, 0, "DICTATION: an explicit dictation result must not submit")
        }
    }

    func testNativeUndoRedoOfNewlineDoesNotSubmit() throws {
        try withField { view in
            view.sendsOnReturn = true
            var sends = 0
            view.submit = { _ in sends += 1 }
            view.setDraft("seed")
            view.selectedRange = NSRange(location: 4, length: 0)
            view.insertText("\n")
            XCTAssertEqual(sends, 1, "SETUP: direct Return must reach the enabled send branch")
            guard sends == 1 else { return }
            sends = 0

            let undo = try XCTUnwrap(view.undoManager, "SETUP: the focused native field needs an undo manager")
            let groupsByEvent = undo.groupsByEvent
            defer { undo.removeAllActions(); undo.groupsByEvent = groupsByEvent }
            undo.removeAllActions()
            undo.groupsByEvent = false
            view.sendsOnReturn = false
            undo.beginUndoGrouping()
            view.insertText("\n")
            undo.endUndoGrouping()
            XCTAssertEqual(view.text, "seed\n", "SETUP: native insertion must produce a newline")
            XCTAssertTrue(undo.canUndo, "SETUP: UIKit must register the edit without a custom undo handler")
            guard view.text == "seed\n", undo.canUndo else { return }

            view.sendsOnReturn = true
            undo.undo()
            XCTAssertEqual(view.text, "seed", "UNDO: the native newline edit must actually be reverted")
            XCTAssertEqual(sends, 0, "UNDO: the native inverse edit must not submit")
            XCTAssertTrue(undo.canRedo, "SETUP: native undo must make the edit available for redo")
            guard view.text == "seed", undo.canRedo else { return }
            undo.redo()
            XCTAssertEqual(view.text, "seed\n", "REDO: the native newline edit must actually be restored")
            XCTAssertEqual(sends, 0, "REDO: replaying the native edit must not submit")
        }
    }
}
