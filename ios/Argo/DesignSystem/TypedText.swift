// Adapted from nwverse/persona apple/Persona/DesignSystem/TypedText.swift and TextViewScroll.swift @ 3002eb3 (MIT).
import SwiftUI
import UIKit

enum TypedText {
    @MainActor static func commitFocused(into text: Binding<String>) {
        guard let view = FirstResponder.current as? (UIResponder & UITextInput) else { return }
        if view.markedTextRange != nil { view.unmarkText() }
        guard let all = view.textRange(from: view.beginningOfDocument, to: view.endOfDocument),
              let shown = view.text(in: all), shown != text.wrappedValue else { return }
        text.wrappedValue = shown
    }
}

private enum FirstResponder {
    @MainActor static weak var found: UIResponder?
    @MainActor static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.argoFindFirstResponder(_:)), to: nil, from: nil, for: nil)
        defer { found = nil }
        return found
    }
}

private extension UIResponder {
    @objc func argoFindFirstResponder(_ sender: Any?) { FirstResponder.found = self }
}
