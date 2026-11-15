// Adapted from nwverse/persona apple/Persona/Views/Chat/FileAttach.swift and
// PhotoAttach.swift @ 3002eb3 (MIT). Argo stages private files, never base64 messages.
import ArgoMobileKit
import CoreTransferable
import Foundation
import ImageIO
import Observation
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

nonisolated enum FileAttach {
    @MainActor static func inputs(_ urls: [URL]) -> [AttachmentInput] {
        urls.map { url in
            // Acquire while the picker still grants access, including time spent
            // waiting behind a preceding selection. Release after coordination.
            let source = ScopedAttachmentSource(url)
            return AttachmentInput(name: url.lastPathComponent, kind: .file) { try await source.stage() }
        }
    }
}

private nonisolated final class ScopedAttachmentSource: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    private let coordinator = NSFileCoordinator()

    init(_ url: URL) { self.url = url; scoped = url.startAccessingSecurityScopedResource() }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func stage() async throws -> ArgoLocalAttachment {
        let work = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            var coordinationError: NSError?
            var result: Result<ArgoLocalAttachment, Error>?
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
                result = Result { try ArgoLocalAttachment.copy(source, name: url.lastPathComponent) }
            }
            if let coordinationError { throw coordinationError }
            try Task.checkCancellation()
            guard let result else { throw CocoaError(.fileReadUnknown) }
            return try result.get()
        }
        let file = try await withTaskCancellationHandler { try await work.value } onCancel: {
            self.coordinator.cancel()
            work.cancel()
        }
        try Task.checkCancellation()
        return file
    }
}

nonisolated enum PhotoAttach {
    static let maxSide = 1600
    static let jpegQuality = 0.75

    /// Called only by the native PasteButton's payload action. Retain providers,
    /// not image bytes; the existing preparation queue loads/encodes serially.
    @MainActor static func inputs(providers: [NSItemProvider]) -> [AttachmentInput] {
        providers.map { provider in
            let source = PastedImageSource(provider)
            return AttachmentInput(name: "Photo.jpg", kind: .photo) { try await source.stage() }
        }
    }

    @MainActor static func inputs(_ items: [PhotosPickerItem]) -> [AttachmentInput] {
        items.map { item in
            return AttachmentInput(name: "Photo.jpg", kind: .photo) {
                try Task.checkCancellation()
                let request = AttachmentSelectionRequest<ImportedPhoto?>()
                let result = try await request.load { done in
                    let progress = item.loadTransferable(type: ImportedPhoto.self, completionHandler: done)
                    return { progress.cancel() }
                }
                guard let imported = result else {
                    throw ArgoClientError.refusedLocally(.message("The photo could not be read. It may still be downloading from iCloud."))
                }
                try Task.checkCancellation()
                return imported.file
            }
        }
    }

    static func inputs(assetIDs: [String]) -> [AttachmentInput] {
        assetIDs.map { id in
            AttachmentInput(name: "Photo.jpg", kind: .photo) {
                let data = try await AttachLibrary.photoData(id)
                let work = Task.detached(priority: .userInitiated) { try encode(source: CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)) }
                return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            }
        }
    }

    /// FileRepresentation keeps system picker bytes on disk. ImageIO decodes
    /// only a transformed thumbnail, with no four-image Data array in the model.
    static func encode(url: URL) throws -> ArgoLocalAttachment {
        try encode(source: CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary))
    }

    private static func encode(source: CGImageSource?) throws -> ArgoLocalAttachment {
        try Task.checkCancellation()
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else {
            throw ArgoClientError.refusedLocally(.message("The photo could not be read. It may still be downloading from iCloud."))
        }
        return try ArgoLocalAttachment.create(name: "Photo.jpg", mime: "image/jpeg", kind: .photo) { url in
            guard let encoder = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(encoder, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw CocoaError(.fileWriteUnknown) }
        }
    }
}

private nonisolated final class PastedImageSource: @unchecked Sendable {
    private let provider: NSItemProvider
    init(_ provider: NSItemProvider) { self.provider = provider }

    func stage() async throws -> ArgoLocalAttachment {
        try Task.checkCancellation()
        let request = AttachmentSelectionRequest<ArgoLocalAttachment>()
        return try await request.load { [self] done in
            let progress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                if let error { done(.failure(error)); return }
                guard let url else {
                    done(.failure(ArgoClientError.refusedLocally(.message("The pasted image could not be read."))))
                    return
                }
                // The provider's temporary URL is valid only during this callback.
                // Decode a <=1600px thumbnail and create the existing private file
                // before returning; never retain provider URLs or full UIImage/Data.
                done(Result { try PhotoAttach.encode(url: url) })
            }
            return { progress.cancel() }
        }
    }
}

private nonisolated struct ImportedPhoto: Transferable, Sendable {
    let file: ArgoLocalAttachment
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let url = received.file
            let work = Task.detached(priority: .userInitiated) { ImportedPhoto(file: try PhotoAttach.encode(url: url)) }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
    }
}

/// Completes exactly once even when Photos calls back synchronously, emits a
/// degraded result, or cancels before it returns a request ID.
private nonisolated final class AttachmentSelectionRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var cancelAction: (@Sendable () -> Void)?
    private var finished = false
    private var cancelled = false

    func load(_ start: @Sendable (@escaping @Sendable (Result<Value, Error>) -> Void) -> (@Sendable () -> Void)?) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if finished { lock.unlock(); c.resume(throwing: CancellationError()); return }
                continuation = c
                lock.unlock()
                let action = start { self.complete($0) }
                lock.lock()
                let cancel = cancelled
                if !finished { cancelAction = action }
                lock.unlock()
                if cancel { action?() }
            }
        } onCancel: { self.cancel() }
    }

    private func complete(_ result: Result<Value, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        cancelAction = nil
        lock.unlock()
        c?.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        cancelled = true
        let c = continuation
        continuation = nil
        let action = cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
        c?.resume(throwing: CancellationError())
    }
}

nonisolated struct PhotoThumbnail: @unchecked Sendable { let image: UIImage }

@MainActor @Observable final class AttachLibrary {
    enum Access { case unknown, full, limited, denied }
    private(set) var access: Access = .unknown
    private(set) var assets: [PHAsset] = []

    func load() async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard !Task.isCancelled else { return }
        switch status {
        case .authorized: access = .full
        case .limited: access = .limited
        default: access = .denied; assets = []; return
        }
        let work = Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            options.fetchLimit = 240
            let result = PHAsset.fetchAssets(with: options)
            var assets: [PHAsset] = []
            result.enumerateObjects { asset, _, _ in assets.append(asset) }
            return FetchedAssets(assets: assets)
        }
        let fetched = await work.value
        guard !Task.isCancelled else { return }
        assets = fetched.assets
    }

    private nonisolated struct FetchedAssets: @unchecked Sendable { let assets: [PHAsset] }

    @concurrent nonisolated static func photoData(_ id: String) async throws -> Data {
        let manager = PHImageManager.default()
        let request = AttachmentSelectionRequest<Data>()
        return try await request.load { done in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                done(.failure(ArgoClientError.refusedLocally(.message("The selected photo is no longer available."))))
                return nil
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            let id = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                if info?[PHImageCancelledKey] as? Bool == true { done(.failure(CancellationError())); return }
                if let error = info?[PHImageErrorKey] as? Error { done(.failure(error)); return }
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                if let data { done(.success(data)) }
                else { done(.failure(ArgoClientError.refusedLocally(.message("The photo could not be read. It may still be downloading from iCloud.")))) }
            }
            return { manager.cancelImageRequest(id) }
        }
    }

    @concurrent nonisolated static func thumbnail(id: String, side: CGFloat) async throws -> PhotoThumbnail {
        let manager = PHImageManager.default()
        let request = AttachmentSelectionRequest<PhotoThumbnail>()
        return try await request.load { done in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
                done(.failure(CocoaError(.fileNoSuchFile))); return nil
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            options.deliveryMode = .highQualityFormat
            let requestID = manager.requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options) { image, info in
                if info?[PHImageCancelledKey] as? Bool == true { done(.failure(CancellationError())); return }
                if let error = info?[PHImageErrorKey] as? Error { done(.failure(error)); return }
                if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                if let image { done(.success(PhotoThumbnail(image: image))) }
                else { done(.failure(CocoaError(.fileReadUnknown))) }
            }
            return { manager.cancelImageRequest(requestID) }
        }
    }
}
