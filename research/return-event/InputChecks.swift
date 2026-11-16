@main struct Checks {
    @MainActor static func main() {
        var failures: Set<String> = []
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            if !condition { failures.insert(name) }
            print("\(condition ? "PASS" : "FAIL") \(name)")
        }
        func field(_ draft: String = "待确认") -> (ComposerTextView, ComposerTextInput, Coordinator) {
            let parent = ComposerTextInput(draft)
            let coordinator = Coordinator(parent)
            let view = ComposerTextView()
            view.acceptsInput = { parent.acceptsInput() }
            view.sendsOnReturn = true
            view.submit = { coordinator.submit($0) }
            view.delegate = DelegateForwarder()
            view.delegate?.textViewDidChange = { coordinator.textViewDidChange($0) }
            coordinator.updateDraft(view)
            return (view, parent, coordinator)
        }
        for text in ["\n", "\r\n", "第一行\n第二行", "🧑🏽‍💻\n"] {
            let (view, parent, _) = field()
            var sends = 0
            parent.send = { sends += 1; parent.text = "" }
            let end = view.endOfDocument
            _ = view.textPasteConfigurationSupporting(view, performPasteOf: NSAttributedString(string: text),
                                                     to: UITextRange(end, end))
            check(sends == 0 && parent.text == "待确认" + text && view.text == parent.text,
                  "Paste/Drop preserves exact inserted text \(String(reflecting: text))")
        }
        let (drop, dropParent, _) = field("甲乙丙")
        var dropSends = 0
        dropParent.send = { dropSends += 1 }
        let inserted = drop.textPasteConfigurationSupporting(drop, performPasteOf: NSAttributedString(string: "\n"),
                                                             to: UITextRange(1, 2))
        check(dropSends == 0 && dropParent.text == "甲\n丙" && inserted.start == 1 && inserted.end == 2,
              "Drop honors UIKit's nonempty replacement range")
        check(dropParent.selection == NSRange(location: 2, length: 0), "Paste caret uses UTF-16 insertion endpoint")
        drop.replace(UITextRange(2, 2), withText: "\n")
        check(dropSends == 0 && dropParent.text == "甲\n\n丙", "Replacement reentry cannot submit")

        let (key, keyParent, coordinator) = field()
        var sends = 0
        var sent: [String] = []
        keyParent.send = {
            if !keyParent.text.isEmpty { sends += 1; sent.append(keyParent.text); keyParent.text = "" }
        }
        key.insertText("\n")
        check(sends == 1 && sent == ["待确认"] && key.text.isEmpty && keyParent.text.isEmpty,
              "Keyboard Return submits once and clears the native buffer synchronously")
        key.insertText("\n")
        check(sends == 1 && key.text.isEmpty, "Second Return cannot restore or resend the cleared draft")
        keyParent.text = "程序更新\n"
        coordinator.updateDraft(key)
        check(sends == 1 && key.text == "程序更新\n", "Programmatic binding update only edits the draft")

        for modifier in KeyCode.allCases {
            GCKeyboard.coalesced = GCKeyboard(keyboardInput: KeyboardInput(held: [modifier]))
            let (view, parent, _) = field()
            var sends = 0
            parent.send = { sends += 1 }
            view.insertText("\n")
            check(sends == 0 && parent.text == "待确认\n", "UIKeyInput preserves hardware modifier \(modifier)")
        }
        GCKeyboard.coalesced = nil
        for enabled in [false, true] {
            let (view, parent, _) = field()
            view.sendsOnReturn = enabled
            var sends = 0
            parent.send = { sends += 1; parent.text = "" }
            view.insertLineBreak()
            check(sends == 0 && parent.text == "待确认\n", "Shift/Option command inserts a newline (setting=\(enabled))")
        }
        let (page, pageParent, _) = field()
        page.sendsOnReturn = false
        var pageSends = 0
        pageParent.send = { pageSends += 1 }
        page.insertText("\n")
        check(pageSends == 0 && pageParent.text == "待确认\n", "Default setting/full-page Return remains a newline")

        let (ime, imeParent, imeCoordinator) = field()
        var imeSends = 0
        imeParent.send = { imeSends += 1; imeParent.text = "" }
        ime.markedTextRange = UITextRange(0, 3)
        ime.insertText("\n")
        check(imeSends == 0, "Marked-text Return belongs to the IME")
        let before = ime.text
        imeParent.text = "deferred model update"
        imeCoordinator.updateDraft(ime)
        check(ime.text == before && ime.markedTextRange != nil, "Render during composition does not replace text or unmark")
        check((ime.keyCommands ?? []).isEmpty, "IME keeps UIKit's Return commands")
        ime.markedTextRange = nil
        imeParent.text = ime.text
        ime.insertText("\n")
        check(imeSends == 1, "A separate Return after confirmation sends without a stale latch")

        for reason in ["disabled", "unfocused", "revoked"] {
            let (view, parent, _) = field()
            var sends = 0
            parent.send = { sends += 1 }
            if reason == "disabled" { parent.canSend = false }
            if reason == "unfocused" { parent.focused = false; view.isFirstResponder = false }
            if reason == "revoked" { parent.acceptsInput = { false } }
            view.insertText("\n")
            check(sends == 0, "\(reason) composer never submits")
            if reason == "disabled" { check(view.text == "待确认", "Unavailable send consumes Return without newline") }
            if reason == "revoked" {
                let before = view.text
                _ = view.textPasteConfigurationSupporting(view, performPasteOf: NSAttributedString(string: "\n"),
                                                         to: UITextRange(0, 0))
                check(view.text == before && parent.text == "待确认", "Late asynchronous paste is rejected after owner revocation")
            }
        }
        let (selectionView, selectionParent, selectionCoordinator) = field("🧑🏽‍💻甲乙")
        selectionParent.selection = NSRange(location: 7, length: 1)
        selectionCoordinator.updateDraft(selectionView)
        check(selectionView.selectedRange == NSRange(location: 7, length: 1), "Native selection round trip uses UTF-16")
        selectionParent.text = ""
        selectionCoordinator.updateDraft(selectionView)
        check(selectionView.selectedRange == NSRange(location: 0, length: 0), "Clear clamps the old selection to the empty draft")
        selectionView.wantsFocus = false
        selectionView.updateFocus()
        check(!selectionView.isFirstResponder, "Sheet/keyboard dismissal relinquishes first responder")
        selectionView.wantsFocus = true
        selectionView.window = nil
        selectionView.updateFocus()
        check(!selectionView.isFirstResponder, "Focus waits for the native view to join a window")
        selectionView.window = 1
        selectionView.didMoveToWindow()
        check(selectionView.isFirstResponder, "Attached field honors requested focus")
        selectionParent.acceptsInput = { false }
        selectionView.updateFocus()
        check(!selectionView.isFirstResponder, "Revoked owner relinquishes native focus")
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
        exit(failures.isEmpty ? 0 : 1)
    }
}
