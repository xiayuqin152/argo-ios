// Adapted from nwverse/persona apple/Persona/Views/Chat/AttachSheet.swift @ 3002eb3 (MIT).
// Retains the half/full sheet, three-column Recents, Photos/Files pill and caption.
import ArgoMobileKit
import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor @Observable final class AttachPanel {
    enum Outcome { case closed, send, allPhotos, files }
    let presentation = SeenPresentation()
    var picked: [String] = []
    var outcome: Outcome = .closed
    var identity: ArgoAgentIdentity?

    func leave(_ outcome: Outcome) {
        self.outcome = outcome
        presentation.requestDismissal()
    }
}

private enum AttachTab: String, CaseIterable, Identifiable {
    case photos, files
    var id: String { rawValue }
    var title: String { L10n.text(self == .photos ? "Photos" : "Files") }
    var symbol: String { self == .photos ? "photo.on.rectangle" : "doc" }
}

struct AttachSheet: View {
    @Bindable var panel: AttachPanel
    @Binding var caption: String
    let room: Int
    let canSend: Bool
    @State private var library = AttachLibrary()
    @State private var tab: AttachTab = .photos
    @State private var detent: PresentationDetent = .medium
    @State private var problem: String?
    @FocusState private var captionFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            if tab == .photos { photos }
            else {
                List {
                    Section {
                        Button { leave(.files) } label: { Label("Browse Files", systemImage: "doc") }
                            .disabled(panel.picked.count >= room)
                            .accessibilityIdentifier("attach-browse-files")
                    } footer: { Text("A file goes to this conversation's computer. Its real path is sent to the Agent.") }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.Shell.composer.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .task(id: scenePhase) { if scenePhase == .active { await library.load() } }
        .onChange(of: captionFocused) { _, focused in if focused { detent = .large } }
        .accessibilityIdentifier("attach-sheet")
    }

    private var header: some View {
        HStack {
            Button { leave(.closed) } label: { Image(systemName: "xmark").tapTargetFrame() }
                .buttonStyle(.plain).accessibilityLabel("Close")
            Spacer(minLength: Theme.Space.xs)
            Text(tab == .photos ? L10n.text("Recents") : tab.title)
                .font(Theme.Font.heading).accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Space.xs)
            if tab == .photos {
                Button("All Photos") { leave(.allPhotos) }.font(Theme.Font.secondaryMedium).tapTargetHeight()
                    .disabled(panel.picked.count >= room)
                    .accessibilityIdentifier("attach-all-photos")
            }
        }
        .padding(.horizontal, Theme.Space.m).padding(.top, Theme.Space.l).padding(.bottom, Theme.Space.xs)
    }

    @ViewBuilder private var photos: some View {
        switch library.access {
        case .unknown: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            ContentUnavailableView {
                Label("Photo access is off", systemImage: "photo")
            } description: {
                Text("Choose photos with All Photos, or allow photo access in Settings.")
            } actions: {
                Button("All Photos") { leave(.allPhotos) }.tapTargetHeight().disabled(panel.picked.count >= room)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }.tapTargetHeight()
            }
        case .full, .limited:
            GeometryReader { geometry in
                let side = max(1, (geometry.size.width - Theme.Attach.gridSpacing * 2) / 3)
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        if library.access == .limited {
                            HStack {
                                Text("Only selected photos are shown.").font(Theme.Font.caption)
                                Spacer()
                                Button("All Photos") { leave(.allPhotos) }.tapTargetHeight().disabled(panel.picked.count >= room)
                            }.padding(.horizontal, Theme.Space.l)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: Theme.Attach.gridSpacing), count: 3), spacing: Theme.Attach.gridSpacing) {
                            ForEach(library.assets, id: \.localIdentifier) { asset in
                                AttachPhotoCell(id: asset.localIdentifier, side: side,
                                                number: panel.picked.firstIndex(of: asset.localIdentifier).map { $0 + 1 }) {
                                    toggle(asset.localIdentifier)
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var bar: some View {
        VStack(spacing: Theme.Space.s) {
            if let problem { Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(Theme.danger) }
            if panel.picked.isEmpty {
                HStack(spacing: 0) {
                    ForEach(AttachTab.allCases) { next in
                        Button { tab = next; detent = .large } label: {
                            VStack(spacing: Theme.Space.xxs) {
                                Image(systemName: next.symbol).font(Theme.Font.heading)
                                Text(verbatim: next.title).font(Theme.Font.label)
                            }
                            .foregroundStyle(tab == next ? Theme.accent : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background { if tab == next { Capsule().fill(Theme.Fill.chip) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == next ? .isSelected : [])
                    }
                }
                .padding(Theme.Attach.barLensInset)
                .frame(width: Theme.Attach.barWidth, height: Theme.Attach.barHeight)
                .modifier(ComposerSurface())
            } else {
                HStack(alignment: .bottom, spacing: Theme.Space.xs) {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .lineLimit(1...4).font(Theme.Font.body).focused($captionFocused)
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.s)
                        .frame(minHeight: Theme.Size.tapTarget).modifier(ComposerSurface())
                        .accessibilityIdentifier("attach-caption")
                    ComposerRoundButton(symbol: Theme.Icon.send, label: L10n.text("Send"), id: "attach-send") {
                        leave(.send)
                    }.disabled(!canSend)
                }.padding(.horizontal, Theme.Space.l)
            }
        }
        .padding(.bottom, Theme.Space.s).frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : Theme.Motion.state, value: panel.picked.isEmpty)
    }

    private func leave(_ outcome: AttachPanel.Outcome) {
        if captionFocused { TypedText.commitFocused(into: $caption) }
        captionFocused = false
        panel.leave(outcome)
    }

    private func toggle(_ id: String) {
        if let index = panel.picked.firstIndex(of: id) { panel.picked.remove(at: index); problem = nil }
        else if panel.picked.count < room { panel.picked.append(id); problem = nil }
        else { problem = L10n.text("Up to 4 attachments per message.") }
    }
}

private struct AttachPhotoCell: View {
    let id: String
    let side: CGFloat
    let number: Int?
    let toggle: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else {
                    Theme.Fill.well
                    Image(systemName: failed ? "exclamationmark.triangle" : "photo").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                ZStack {
                    Circle().fill(number == nil ? Color.black.opacity(Theme.Attach.dim) : Theme.accent)
                    Circle().strokeBorder(.white, lineWidth: Theme.Attach.badgeRing)
                    if let number { Text(verbatim: "\(number)").font(Theme.Font.labelStrong).foregroundStyle(.white) }
                }
                .frame(width: Theme.Attach.badge, height: Theme.Attach.badge).padding(Theme.Attach.badgeInset)
            }
            .frame(width: side, height: side).clipped().contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo")
        .accessibilityValue(number.map { String(format: L10n.text("Selected, %@"), String($0)) } ?? L10n.text("Not selected"))
        .accessibilityAddTraits(number != nil ? .isSelected : [])
        .task(id: id) {
            do {
                let thumbnail = try await AttachLibrary.thumbnail(id: id, side: side * scale)
                try Task.checkCancellation()
                image = thumbnail.image
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}
