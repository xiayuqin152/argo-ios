// Adapted from nwverse/persona apple/Persona/Views/Chat/ComposerParts.swift and
// apple/Persona/DesignSystem/ShellComposerBar.swift (ComposerBoxLayout, ComposerSurface) @ 3002eb3 (MIT).
import SwiftUI

/// Persona's original three-subview layout. The same field moves from the line
/// into the card; changing the layout never creates a second editor.
struct ComposerBoxLayout: Layout {
    var open: Bool
    var spacing: CGFloat
    var rowGap: CGFloat
    var rowLeading: CGFloat
    var rowTrailing: CGFloat
    var rowBottom: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(ProposedViewSize(bounds.size), subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 3 else { return (.zero, []) }
        let field = subviews[0], leading = subviews[1], trailing = subviews[2]
        let lead = leading.sizeThatFits(.unspecified)
        if open {
            let width = proposal.width ?? rowLeading + lead.width + rowGap + trailing.sizeThatFits(.unspecified).width + rowTrailing
            let trail = trailing.sizeThatFits(ProposedViewSize(width: max(0, width - rowLeading - lead.width - rowGap - rowTrailing), height: nil))
            let row = max(lead.height, trail.height)
            let top = field.sizeThatFits(ProposedViewSize(width: width, height: proposal.height.map { max(0, $0 - row - rowBottom) }))
            let middle = top.height + row / 2
            return (CGSize(width: width, height: top.height + row + rowBottom), [
                CGRect(x: 0, y: 0, width: width, height: top.height),
                CGRect(x: rowLeading, y: middle - lead.height / 2, width: lead.width, height: lead.height),
                CGRect(x: width - rowTrailing - trail.width, y: middle - trail.height / 2, width: trail.width, height: trail.height),
            ])
        }
        let trail = trailing.sizeThatFits(.unspecified)
        let sides = lead.width + spacing + spacing + trail.width
        let room = proposal.width.map { max(0, $0 - sides) }
        let line = field.sizeThatFits(ProposedViewSize(width: room, height: proposal.height))
        let width = proposal.width ?? sides + line.width
        let height = max(lead.height, line.height, trail.height)
        return (CGSize(width: width, height: height), [
            CGRect(x: lead.width + spacing, y: height - line.height, width: room ?? line.width, height: line.height),
            CGRect(x: 0, y: height - lead.height, width: lead.width, height: lead.height),
            CGRect(x: width - trail.width, y: height - trail.height, width: trail.width, height: trail.height),
        ])
    }
}

struct ComposerSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Theme.Shell.composerRadius, style: .continuous)
                    .fill(Theme.Shell.composer)
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Shell.composerRadius, style: .continuous)
                    .strokeBorder(Theme.Shell.composerStroke, lineWidth: Theme.Size.hairline)
            }
    }
}
