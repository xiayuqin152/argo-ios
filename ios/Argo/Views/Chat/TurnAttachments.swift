// Adapted from nwverse/persona apple/Persona/Views/Chat/TurnAttachments.swift and
// FileAttach.swift @ 3002eb3 (MIT). Cards describe text references, never native images.
import ArgoMobileKit
import SwiftUI
import UIKit

struct AttachmentCards: View {
    let references: [ArgoFileReference]
    let open: (ArgoFileReference) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(Array(references.enumerated()), id: \.offset) { _, reference in
                    Button { open(reference) } label: {
                        AttachmentCard(title: reference.name, subtitle: L10n.text("File reference · Download to view")) {
                            Image(systemName: AttachmentImages.isImage(reference.name) ? "photo" : "doc")
                                .font(Theme.Font.heading).foregroundStyle(.secondary)
                                .frame(width: Theme.Size.wellL, height: Theme.Attach.tileHeight)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("file-card-" + reference.path)
                    .contextMenu { CopyMessageButton(text: reference.path).accessibilityLabel("Copy Path") }
                }
            }
        }
    }
}

struct LocalAttachmentCards: View {
    let files: [ArgoLocalAttachment]
    let open: (ArgoLocalAttachment) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(files, id: \.url) { file in
                    Button { open(file) } label: {
                        if AttachmentImages.isImage(file.name) {
                            LocalPhotoThumb(file: file, height: files.count == 1 ? 80 : Theme.Attach.tileHeight)
                        } else {
                            AttachmentCard(title: file.name, subtitle: L10n.text("Local copy")) {
                                Image(systemName: "doc").font(Theme.Font.heading).foregroundStyle(.secondary)
                                    .frame(width: Theme.Size.wellL, height: Theme.Attach.tileHeight)
                            }
                        }
                    }
                    .buttonStyle(.plain).accessibilityLabel(file.name)
                }
            }
        }
    }
}

private struct LocalPhotoThumb: View {
    let file: ArgoLocalAttachment
    let height: CGFloat
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Theme.Fill.well
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }
        .frame(width: height * 1.25, height: height).clipped()
        .clipShape(.rect(cornerRadius: Theme.Radius.control))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.cardStroke, lineWidth: Theme.Size.hairline) }
        .task(id: file.url) {
            do {
                let thumbnail = try await AttachmentImages.thumbnail(file, side: 240)
                try Task.checkCancellation()
                image = thumbnail?.image
            } catch { /* The tappable viewer reports the read error. */ }
        }
    }
}

struct AttachmentCard<Thumb: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var thumb: Thumb
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            thumb
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(verbatim: title).font(Theme.Font.secondaryStrong).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                Text(verbatim: subtitle).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(width: Theme.Attach.cardWidth, height: Theme.Attach.tileHeight, alignment: .leading)
        .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
        .contentShape(.rect(cornerRadius: Theme.Radius.card))
    }
}

struct DraftAttachments: View {
    @Bindable var state: ConversationState
    let open: (ArgoLocalAttachment) -> Void
    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            let photos = state.attachments.compactMap(\.local).filter { $0.kind == .photo }
            if !photos.isEmpty { LocalAttachmentCards(files: photos, open: open) }
            ForEach(state.attachments) { item in
                AttachmentRow(symbol: item.kind == .photo ? "photo" : "doc", name: item.name,
                              status: status(item), busy: item.phase == .preparing || item.phase == .uploading,
                              open: item.local.map { file in { open(file) } },
                              remove: { state.removeAttachment(item.id) })
            }
            if let batch = state.attachmentSendID {
                Button("Cancel Upload") {
                    guard state.attachmentSendID == batch else { return }
                    state.cancelAttachmentWork()
                }.font(Theme.Font.captionStrong).tapTargetHeight()
            }
            if let problem = state.attachmentProblem {
                Text(verbatim: problem).font(Theme.Font.caption).foregroundStyle(Theme.danger)
            }
        }
    }

    private func status(_ item: DraftAttachment) -> String {
        switch item.phase {
        case .waiting: L10n.text("Waiting")
        case .preparing: L10n.text("Preparing attachment…")
        case .readyLocal: item.local.map { ByteCountFormatter.string(fromByteCount: Int64($0.size), countStyle: .file) } ?? ""
        case .uploading: L10n.text("Uploading…")
        case .readyRemote: L10n.text("Uploaded · Message not sent yet")
        case .failed(let error): error
        }
    }
}

/// Persona's file row: icon, name/status, actual activity and cancel/remove.
/// The transport exposes no byte progress; an indeterminate indicator stays honest.
struct AttachmentRow: View {
    let symbol: String
    let name: String
    let status: String
    let busy: Bool
    var open: (() -> Void)?
    let remove: () -> Void
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button { open?() } label: {
                Image(systemName: symbol).font(Theme.Font.body).foregroundStyle(.secondary).tapTargetFrame()
            }.buttonStyle(.plain).disabled(open == nil).accessibilityLabel("Preview local copy")
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(verbatim: name).font(Theme.Font.secondary).lineLimit(1).truncationMode(.middle)
                HStack {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(verbatim: status).font(Theme.Font.label).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").font(Theme.Font.title).foregroundStyle(.secondary).tapTargetFrame() }
                .buttonStyle(.plain).accessibilityLabel("Remove attachment")
        }
        .padding(.horizontal, Theme.Space.s).padding(.vertical, Theme.Space.xs)
        .background(Theme.Fill.well, in: .rect(cornerRadius: Theme.Radius.card))
    }
}
