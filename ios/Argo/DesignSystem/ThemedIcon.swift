// Adapted from nwverse/persona apple/Persona/DesignSystem/ThemedIcon.swift @ 3002eb3 (MIT).
import SwiftUI

/// Persona's Liquid Glass style leaves SF Symbols in the system's own weight.
struct ThemedIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View { Image(systemName: name) }
}
