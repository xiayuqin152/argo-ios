// Adapted from nwverse/Persona apple/Persona/Views/Chat/PasteImageChip.swift
// @ 89927b54baab6b8207315f6c2a4d2e5831598d45 (MIT).
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// The system button supplies providers only after an intentional paste.
/// No clipboard content polling, UIImage/Data array, or automatic paste.
struct PasteImageChip: View {
    let focused: Bool
    let enabled: Bool
    let paste: ([NSItemProvider]) -> Void

    var body: some View {
        if focused {
            HStack {
                PasteButton(supportedContentTypes: [.image], payloadAction: paste)
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .disabled(!enabled)
                    .accessibilityLabel("Paste Image")
                    .accessibilityIdentifier("composer-paste-image")
                Spacer(minLength: Theme.Space.xs)
            }
        }
    }
}
