// Adapted from nwverse/persona apple/Persona/DesignSystem/TextSize.swift @ 3002eb3 (MIT).
import SwiftUI

extension View {
    func lineHeight(_ level: Theme.Level) -> some View { modifier(LineHeight(level: level)) }
    func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, alignment: alignment))
    }
    func tapTargetFrame() -> some View {
        scaledFrame(width: Theme.Size.tapTarget, height: Theme.Size.tapTarget)
            .frame(minWidth: Theme.Size.tapTarget, minHeight: Theme.Size.tapTarget)
    }
    func tapTargetHeight() -> some View { frame(minHeight: Theme.Size.tapTarget) }

    func scaledFrame(minWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil,
                     maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        modifier(ScaledFlexibleFrame(minWidth: minWidth, maxWidth: maxWidth,
                                     minHeight: minHeight, maxHeight: maxHeight, alignment: alignment))
    }
}

private struct LineHeight: ViewModifier {
    let level: Theme.Level
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    func body(content: Content) -> some View { content.lineSpacing(level.extraLeading * scale) }
}

private struct ScaledFlexibleFrame: ViewModifier {
    let minWidth: CGFloat?, maxWidth: CGFloat?, minHeight: CGFloat?, maxHeight: CGFloat?
    let alignment: Alignment
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    private func scaled(_ value: CGFloat?) -> CGFloat? {
        value.map { $0.isFinite ? $0 * min(scale, 1.6) : $0 }
    }
    func body(content: Content) -> some View {
        content.frame(minWidth: scaled(minWidth), maxWidth: scaled(maxWidth),
                      minHeight: scaled(minHeight), maxHeight: scaled(maxHeight), alignment: alignment)
    }
}

private struct ScaledFrame: ViewModifier {
    let width: CGFloat?
    let height: CGFloat?
    let alignment: Alignment
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    func body(content: Content) -> some View {
        content.frame(width: width.map { $0 * min(scale, 1.6) },
                      height: height.map { $0 * min(scale, 1.6) }, alignment: alignment)
    }
}
