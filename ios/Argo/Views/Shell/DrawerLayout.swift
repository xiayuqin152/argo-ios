// Adapted from nwverse/persona apple/Persona/Views/Assistant/AssistantSidebar.swift
// (AssistantDrawerLayout, DrawerPageMotion) @ 3002eb3 (MIT).
import SwiftUI
import UIKit

/// Persona's stationary sidebar and whole-page slide. Argo has one Agent page,
/// so no Assistant pager, Hub tab bar, or Persona-specific window probes are needed.
struct PersonaDrawerLayout<Sidebar: View, Page: View>: View {
    @Binding var isPresented: Bool
    var enabled: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var page: Page
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width * 0.82, 380)
            let progress = min(1, max(0, (isPresented ? 1 : 0) + drag / max(width, 1)))
            let out = progress > 0
            let card = RoundedRectangle(cornerRadius: out ? Theme.Radius.page : 0, style: .continuous)
            ZStack(alignment: .leading) {
                sidebar
                    .frame(width: width, height: geometry.size.height)
                    .background(Theme.Shell.drawer)
                    .offset(y: (1 - progress) * Theme.Space.s)
                    .opacity(out ? 1 : 0)
                    .allowsHitTesting(isPresented)
                    .accessibilityHidden(!isPresented)
                page
                    .accessibilityHidden(out)
                    .mask { card.ignoresSafeArea() }
                    .background {
                        card.fill(Theme.pageBackground)
                            .shadow(color: .black.opacity(out ? 0.18 : 0), radius: 24)
                            .ignoresSafeArea()
                    }
                    .overlay {
                        if out {
                            card.fill(Color.black.opacity(0.2 * progress))
                                .overlay(card.strokeBorder(Color.primary.opacity(0.12 * progress), lineWidth: Theme.Size.line))
                                .ignoresSafeArea()
                            Button { isPresented = false } label: { Color.clear.contentShape(.rect) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close Sidebar")
                                .accessibilityIdentifier("argo-drawer-close")
                        }
                    }
                    .offset(x: progress * width)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .background { Theme.Shell.drawer.ignoresSafeArea() }
            .simultaneousGesture(pan(width: width))
            .animation(reduceMotion ? nil : Theme.Motion.drawer, value: isPresented)
            .onChange(of: isPresented) { _, shown in
                if shown { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
            }
        }
    }

    private func accepts(_ value: DragGesture.Value) -> Bool {
        // Leave a message's horizontal code scrolling and the system back swipe alone.
        // Opening starts at the list's leading edge; an open drawer can close anywhere.
        (isPresented || (enabled && value.startLocation.x < Theme.Size.tapTarget)) &&
            abs(value.translation.width) > abs(value.translation.height) &&
            (isPresented || value.translation.width > 0)
    }

    private func pan(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: Theme.Space.l)
            .updating($drag) { value, state, transaction in
                guard accepts(value) else { return }
                transaction.disablesAnimations = true
                state = value.translation.width
            }
            .onEnded { value in
                guard accepts(value) else { return }
                let projected = (isPresented ? width : 0) + value.predictedEndTranslation.width
                isPresented = projected > width / 2
            }
    }
}
