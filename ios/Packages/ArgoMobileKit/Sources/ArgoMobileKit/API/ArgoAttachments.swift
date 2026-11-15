import Foundation

public enum ArgoAttachmentPolicy {
    public static let countLimit = 4
    public static let byteLimit = 10 * 1_048_576
    public static let referenceLimit = 20
    public static let pathByteLimit = 4096

    public static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= pathByteLimit && clean(path)
    }

    public static func validName(_ name: String) -> Bool {
        validReferenceName(name) && !name.contains("/") && name != "." && name != ".."
    }

    // Reference names are display metadata. POSIX basename("/") is "/";
    // a directory mention must not make an otherwise valid chat page unreadable.
    static func validReferenceName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= pathByteLimit && clean(name)
    }

    private static func clean(_ value: String) -> Bool {
        // Match the server's unicode.IsControl (category Cc). Foundation's
        // controlCharacters also includes Cf, including emoji's zero-width joiner.
        value.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control }
    }

    public static var tooLarge: ArgoClientError {
        .refusedLocally(.message("The file exceeds the 10 MiB attachment limit."))
    }
}

/// A server projection of a path mentioned in text. It grants no read permission
/// and never implies a native image message or that an Agent viewed the file.
public struct ArgoFileReference: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let path: String
    public let name: String
    public let origin: String
    public var id: String { path }

    public init(path: String, name: String) throws {
        guard ArgoAttachmentPolicy.validPath(path), ArgoAttachmentPolicy.validReferenceName(name) else {
            throw ArgoClientError.refusedLocally(.message("The file reference is invalid."))
        }
        self.path = path; self.name = name; origin = "text-reference"
    }

    private enum CodingKeys: String, CodingKey { case path, name, origin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        origin = try c.decode(String.self, forKey: .origin)
        guard origin == "text-reference", ArgoAttachmentPolicy.validPath(path), ArgoAttachmentPolicy.validReferenceName(name) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "Invalid text file reference")
        }
    }

    var retainedByteCount: Int { MemoryLayout<Self>.stride + path.utf8.count + name.utf8.count + origin.utf8.count }

    /// Body links can only select a server-projected reference from this message.
    /// Never manufacture provenance from provider-cleaned display text. Web links
    /// stay web links and receive no gateway credential or bearer header.
    public static func link(_ url: URL, references: [Self]) throws -> Self? {
        guard url.isFileURL || (url.scheme == nil && url.relativeString.hasPrefix("/")) else { return nil }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == nil || parts.host == "" || parts.host?.lowercased() == "localhost",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              let path = parts.percentEncodedPath.removingPercentEncoding,
              !path.hasPrefix("//"), ArgoAttachmentPolicy.validPath(path) else {
            throw ArgoClientError.refusedLocally(.message("The file reference is invalid."))
        }
        // Decode exactly once. POSIX path identity is UTF-8 byte identity, not
        // Swift String's canonical Unicode equivalence (e.g. NFC versus NFD).
        guard let reference = references.first(where: { $0.path.utf8.elementsEqual(path.utf8) }) else {
            throw ArgoClientError.refusedLocally(.message("This file link has no verified source in this message."))
        }
        return reference
    }
}

public struct ArgoUploadedFile: Decodable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let size: Int

    public var reference: ArgoFileReference { get throws { try ArgoFileReference(path: path, name: name) } }

    func validate(expectedSize: Int) throws {
        guard ArgoAttachmentPolicy.validPath(path), ArgoAttachmentPolicy.validName(name),
              size >= 0, size == expectedSize, size <= ArgoAttachmentPolicy.byteLimit else {
            throw ArgoClientError.invalidResponse(.message("The host returned an invalid upload receipt."))
        }
    }
}

/// Owns only a uniquely created application-private directory. Drafts, receipts
/// and a presented local preview share this handle; the last release cleans it.
/// Full attachment bytes are never retained by the conversation model.
public final class ArgoLocalAttachment: Sendable {
    public enum Kind: String, Sendable { case photo, file }
    public let url: URL
    public let name: String
    public let mime: String
    public let size: Int
    public let kind: Kind
    private let directory: URL

    private init(directory: URL, name: String, mime: String, size: Int, kind: Kind) {
        self.directory = directory; url = directory.appendingPathComponent(name)
        self.name = name; self.mime = mime; self.size = size; self.kind = kind
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Executes on a caller's background worker. `write` must populate the
    /// supplied URL before returning; failures/cancellation remove only this dir.
    public static func create(name: String, mime: String, kind: Kind, root: URL? = nil,
                              write: (URL) throws -> Void) throws -> ArgoLocalAttachment {
        guard ArgoAttachmentPolicy.validName(name) else {
            throw ArgoClientError.refusedLocally(.message("The attachment name is invalid."))
        }
        try Task.checkCancellation()
        let base = try root ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ArgoAttachments", isDirectory: true)
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let destination = directory.appendingPathComponent(name)
            try write(destination)
            try Task.checkCancellation()
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
                throw ArgoClientError.refusedLocally(.message("Choose an ordinary file, not a folder or package."))
            }
            guard size <= ArgoAttachmentPolicy.byteLimit else { throw ArgoAttachmentPolicy.tooLarge }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return Self(directory: directory, name: name, mime: mime, size: size, kind: kind)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public static func copy(_ source: URL, name: String, mime: String = "application/octet-stream", root: URL? = nil) throws -> ArgoLocalAttachment {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isDirectory != true, values.isPackage != true, values.isSymbolicLink != true else {
            throw ArgoClientError.refusedLocally(.message("Choose an ordinary file, not a folder or package."))
        }
        if let size = values.fileSize, size > ArgoAttachmentPolicy.byteLimit { throw ArgoAttachmentPolicy.tooLarge }
        return try create(name: name, mime: mime, kind: .file, root: root) { destination in
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var count = 0
            while true {
                try Task.checkCancellation()
                let bytes = try input.read(upToCount: 64 * 1024) ?? Data()
                if bytes.isEmpty { break }
                count += bytes.count
                guard count <= ArgoAttachmentPolicy.byteLimit else { throw ArgoAttachmentPolicy.tooLarge }
                try output.write(contentsOf: bytes)
            }
        }
    }
}

struct ArgoAttachmentMultipart {
    let body: Data
    let boundary: String
    let size: Int

    init(file: ArgoLocalAttachment) throws {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: ArgoAttachmentPolicy.byteLimit + 1) ?? Data()
        guard bytes.count <= ArgoAttachmentPolicy.byteLimit else { throw ArgoAttachmentPolicy.tooLarge }
        guard bytes.count == file.size else {
            throw ArgoClientError.refusedLocally(.message("The staged attachment changed. Select it again."))
        }
        // UUID's ASCII alphabet is legal as a MIME boundary and not user input.
        boundary = "Argo-" + UUID().uuidString
        let escaped = file.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        guard file.mime == "image/jpeg" || file.mime == "application/octet-stream" else {
            throw ArgoClientError.refusedLocally(.message("The attachment type is invalid."))
        }
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(escaped)\"\r\nContent-Type: \(file.mime)\r\n\r\n".utf8)
        data.append(bytes)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        body = data; size = bytes.count
    }
}

public enum ArgoAttachmentMessage {
    /// Stable ordered JSON-quoted paths, sent through the existing text queue.
    public static func text(caption: String, files: [(ArgoUploadedFile, ArgoLocalAttachment.Kind)]) throws -> String {
        guard !files.isEmpty, files.count <= ArgoAttachmentPolicy.countLimit else {
            throw ArgoClientError.refusedLocally(.message("Up to 4 attachments per message."))
        }
        let lines = try files.map { file, kind in
            let ref = try file.reference
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let quoted = String(decoding: try encoder.encode(ref.path), as: UTF8.self)
            return (kind == .photo ? "请用图片查看工具查看图片：" : "文件引用：") + quoted
        }
        let text = (caption.isEmpty ? "" : caption + "\n\n") + lines.joined(separator: "\n")
        guard text.utf8.count <= 256 * 1024 else {
            throw ArgoClientError.refusedLocally(.message("The message exceeds 256 KiB."))
        }
        return text
    }
}
