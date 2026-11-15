import ArgoMobileKit
import Foundation
import ImageIO
import QuickLook
import SwiftUI
import UIKit

struct AttachmentPreview: Identifiable {
    enum Source {
        case local(ArgoLocalAttachment)
        case remote(ArgoFileReference, SessionKey, ArgoAgentIdentity)
    }
    let id = UUID()
    let source: Source
}

/// Both text links and historical cards enter here. Every remote presentation
/// downloads afresh: a local receipt copy never substitutes for a 403 or 404.
struct AttachmentViewer: View {
    let preview: AttachmentPreview
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var file: ArgoLocalAttachment?
    @State private var problem: String?
    @State private var image: UIImage?
    @State private var plainText: String?

    var body: some View {
        NavigationStack {
            Group {
                if let problem { ContentUnavailableView { Label("File unavailable", systemImage: "doc.badge.ellipsis") } description: { Text(verbatim: problem) } }
                else if let image {
                    ScrollView([.horizontal, .vertical]) { Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1600, maxHeight: 1600) }
                } else if let plainText {
                    ScrollView { Text(verbatim: plainText).font(Theme.Font.code).textSelection(.enabled).padding(Theme.Space.l) }
                } else if let file { LocalQuickLook(file: file).id(file.url) }
                else { ProgressView("Preparing file preview…") }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() }.tapTargetHeight() }
                ToolbarItem(placement: .bottomBar) {
                    Text(isLocal ? "Local copy" : "Original host file")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: preview.id) {
            file = nil
            image = nil
            plainText = nil
            problem = nil
            do {
                let loaded: ArgoLocalAttachment
                switch preview.source {
                case .local(let local): loaded = local
                case .remote(let reference, let key, let identity):
                    loaded = try await model.downloadAttachment(reference, key: key, identity: identity)
                }
                try Task.checkCancellation()
                let ext = loaded.url.pathExtension.lowercased()
                if ["html", "htm", "svg"].contains(ext) {
                    let text = try await AttachmentImages.text(loaded)
                    try Task.checkCancellation()
                    plainText = text
                } else if AttachmentImages.isImage(loaded.name) {
                    let thumbnail = try await AttachmentImages.thumbnail(loaded, side: 1600)
                    try Task.checkCancellation()
                    guard let thumbnail else { throw CocoaError(.fileReadCorruptFile) }
                    image = thumbnail.image
                } else if !QLPreviewController.canPreviewItem(loaded.url as NSURL) {
                    throw ArgoClientError.refusedLocally(.message("This file type cannot be previewed on this device."))
                }
                file = loaded
            } catch { if !Task.isCancelled { problem = L10n.fileError(error) } }
        }
    }

    private var title: String {
        switch preview.source { case .local(let file): file.name; case .remote(let ref, _, _): ref.name }
    }
    private var isLocal: Bool { if case .local = preview.source { true } else { false } }
}

private struct LocalQuickLook: UIViewControllerRepresentable {
    let file: ArgoLocalAttachment
    func makeCoordinator() -> Coordinator { Coordinator(file: file) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let file: ArgoLocalAttachment
        init(file: ArgoLocalAttachment) { self.file = file }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { file.url as NSURL }
    }
}

nonisolated enum AttachmentImages {
    static func isImage(_ name: String) -> Bool {
        ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains((name as NSString).pathExtension.lowercased())
    }

    static func thumbnail(_ file: ArgoLocalAttachment, side: Int) async throws -> PhotoThumbnail? {
        let work = Task.detached(priority: .userInitiated) { () -> PhotoThumbnail? in
            guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: side,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), !Task.isCancelled else { return nil }
            return PhotoThumbnail(image: UIImage(cgImage: image))
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    static func text(_ file: ArgoLocalAttachment) async throws -> String {
        let work = Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }
            let limit = 256 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            try Task.checkCancellation()
            return String(decoding: data.prefix(limit), as: UTF8.self) + (data.count > limit ? "\n\n" + L10n.text("Text preview limited to 256 KiB.") : "")
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
