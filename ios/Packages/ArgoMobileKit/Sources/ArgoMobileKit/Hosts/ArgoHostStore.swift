import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The phone's paired dev machines. The records (`LoomHost`: address, port,
/// certificate fingerprint, device id; nothing secret) are one JSON file;
/// each device token is in the token store (the Keychain), keyed by host id.
public actor ArgoHostStore {
    /// Exchanges a pairing code for a device credential. The real one is
    /// LoomKit's GatewayPairing (pinned TLS, the code's one-time secret).
    public typealias Pairer = @Sendable (PairingCode, String) async throws -> GatewayCredential

    private let fileURL: URL
    private let tokens: any DeviceTokenStoring
    private let pairer: Pairer

    public init(fileURL: URL, tokens: any DeviceTokenStoring, pairer: @escaping Pairer) {
        self.fileURL = fileURL
        self.tokens = tokens
        self.pairer = pairer
    }

    #if canImport(Network)
    public init(fileURL: URL, tokens: any DeviceTokenStoring) {
        self.init(fileURL: fileURL, tokens: tokens) { code, name in
            try await GatewayPairing.pair(code, name: name)
        }
    }
    #endif

    /// Application Support/Argo/hosts.json.
    public static func defaultFileURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Argo", isDirectory: true).appendingPathComponent("hosts.json")
    }

    /// The saved hosts in the order they were added. No file is no hosts; a
    /// file that cannot be read throws (it is never replaced silently).
    public func hosts() throws -> [LoomHost] {
        let saved = try read()
        guard saved.pendingCredentialCleanup?.isEmpty == false else { return saved.hosts }
        // Another store may be between its token save and metadata commit.
        // Its last host list is readable; its cleanup intent is not abandoned.
        guard let lock = try HostCredentialFileLock(fileURL) else { return saved.hosts }
        return try withExtendedLifetime(lock) { try recover(read()).hosts }
    }

    private func read() throws -> HostFile {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return HostFile(hosts: [])
        } catch {
            throw LoomError.message("读不了已保存的主机（\(fileURL.lastPathComponent)）：\(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(HostFile.self, from: data)
        } catch {
            throw LoomError.message("已保存的主机文件已损坏（\(fileURL.path)），没有改动它。删除它后可重新配对。")
        }
    }

    /// Pairs with the dev machine a code names (`argo pair` prints it) and
    /// saves it. A host already saved at the same address and port is
    /// re-paired in place (same id, new certificate pin and credential).
    public func pair(code text: String, deviceName: String, name: String? = nil) async throws -> LoomHost {
        try Task.checkCancellation()
        let code: PairingCode
        do { code = try PairingCode(parsing: text) }
        catch {
            throw ArgoClientError.refusedLocally(.message("Invalid pairing code. Copy the complete code printed by argo pair on the host."))
        }
        let credential = try await pairer(code, String(deviceName.prefix(64)))
        try Task.checkCancellation()
        guard GatewayCredential.validDevice(credential.device), GatewayCredential.validToken(credential.token) else {
            throw GatewayError.protocolError("网关返回的设备凭据格式不对（远程上的 Argo 版本可能不匹配）")
        }
        let lock = try exclusiveAccess()
        defer { withExtendedLifetime(lock) {} }
        let previous = try recover(read())
        var list = previous.hosts
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var host: LoomHost
        let existing = list.firstIndex(where: { $0.address.caseInsensitiveCompare(code.host) == .orderedSame && $0.gatewayPort == code.port })
        if let i = existing {
            host = list[i]
            host.fingerprint = Base64URL.encode(code.fingerprint)
            host.deviceID = credential.device
            if !trimmed.isEmpty { host.name = trimmed }
            list[i] = host
        } else {
            host = LoomHost(name: trimmed.isEmpty ? code.host : trimmed, address: code.host, gatewayPort: code.port,
                            fingerprint: Base64URL.encode(code.fingerprint), deviceID: credential.device)
            list.append(host)
        }
        try host.validate()
        let previousToken = try tokens.read(host.id)
        if existing == nil {
            // Claim only this newly allocated account before creating its
            // token. Never infer ownership from the shared Keychain service.
            var pending = previous
            pending.pendingCredentialCleanup = [host.id]
            try write(pending)
        }
        do {
            try tokens.save(credential.token, for: host.id)
            try write(HostFile(hosts: list))
        } catch {
            // Metadata still names the old device and certificate if its
            // atomic write failed. Keep the matching old token with it.
            if let previousToken {
                do { try tokens.save(previousToken, for: host.id) }
                catch { throw LoomError.message("保存主机失败，旧设备凭据也无法恢复，请重新配对：\(error.localizedDescription)") }
            } else {
                do { try tokens.delete(host.id) }
                catch let cleanupError {
                    throw ArgoClientError.invalidResponse(.message("Could not save the host: %@. Removing its new device credential also failed: %@. Pair again.",
                        arguments: [error.localizedDescription, cleanupError.localizedDescription]))
                }
            }
            // A new pairing's intent stays durable until a later successful
            // load clears it, even if immediate token cleanup succeeded.
            throw error
        }
        return host
    }

    public func rename(_ id: UUID, to name: String) throws -> LoomHost {
        let lock = try exclusiveAccess()
        defer { withExtendedLifetime(lock) {} }
        var saved = try recover(read())
        var list = saved.hosts
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw LoomError.message("这台主机已被删除") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LoomError.message("名称不能为空") }
        var renamed = list[i]
        renamed.name = String(trimmed.prefix(64))
        if let other = HostNames.clash(renamed, in: list) { throw LoomError.message(HostNames.clashMessage(other.displayName)) }
        list[i] = renamed
        saved.hosts = list
        try write(saved)
        return renamed
    }

    /// Forgets a host and its device token. The dev machine keeps its device
    /// record until `argo devices revoke`.
    public func remove(_ id: UUID) throws {
        let lock = try exclusiveAccess()
        defer { withExtendedLifetime(lock) {} }
        let previous = try recover(read())
        // Unknown ids have no ownership proof. A known pending removal was
        // already retried by recover(), including after an app restart.
        guard previous.hosts.contains(where: { $0.id == id }) else { return }
        var removed = previous
        removed.hosts.removeAll { $0.id == id }
        removed.pendingCredentialCleanup = [id]
        try write(removed)
        do { try tokens.delete(id) }
        catch let deletionError {
            do { try write(previous) }
            catch let restoreError {
                // The same atomic file still owns the pending cleanup id;
                // load/retry can find it without the previous process's UI.
                throw ArgoClientError.invalidResponse(.message("Could not remove the device credential: %@. Restoring the saved host also failed: %@. Try Forget Host again.",
                    arguments: [deletionError.localizedDescription, restoreError.localizedDescription]))
            }
            throw deletionError
        }
        removed.pendingCredentialCleanup = nil
        try write(removed)
    }

    /// What launching this host needs (LoomKit HostLaunch): connect, pair
    /// again, or ask for the Keychain later.
    public func launchOutcome(for host: LoomHost) -> HostLaunchOutcome {
        HostLaunch.outcome(for: host) {
            do { return try tokens.read(host.id) == nil ? .missing : .available }
            catch { return .unavailable(reason: error.localizedDescription) }
        }
    }

    /// The host's gateway credential; `.needsPairing` without a token.
    public func credential(for host: LoomHost) throws -> GatewayCredential {
        let lock = try exclusiveAccess()
        defer { withExtendedLifetime(lock) {} }
        do { try host.validate() } catch { throw ArgoClientError.needsPairing(.message("The saved pairing details are invalid. Pair this host again.")) }
        guard try recover(read()).hosts.contains(where: {
            $0.id == host.id && $0.address == host.address && $0.gatewayPort == host.gatewayPort
                && $0.fingerprint == host.fingerprint && $0.deviceID == host.deviceID
        }) else { throw ArgoClientError.needsPairing(.message("This host was removed or paired again. Select the host again.")) }
        guard let token = try tokens.read(host.id) else { throw ArgoClientError.needsPairing(.message("No device credential is saved for this host. Run argo pair on the host and pair again.")) }
        return GatewayCredential(device: host.deviceID, token: token)
    }

    private struct HostFile: Codable {
        var version = 1
        var hosts: [LoomHost]
        /// Only operations staged in this exact metadata file can authorize
        /// cleanup. Absent in older files; no service-wide legacy migration.
        var pendingCredentialCleanup: [UUID]? = nil
    }

    private func recover(_ saved: HostFile) throws -> HostFile {
        guard let pending = saved.pendingCredentialCleanup, !pending.isEmpty else { return saved }
        for id in pending where !saved.hosts.contains(where: { $0.id == id }) {
            try tokens.delete(id)
        }
        var recovered = saved
        recovered.pendingCredentialCleanup = nil
        try write(recovered)
        return recovered
    }

    private func exclusiveAccess() throws -> HostCredentialFileLock {
        guard let lock = try HostCredentialFileLock(fileURL) else {
            throw LoomError.message("The saved host store is busy. Try again.")
        }
        return lock
    }

    private func write(_ saved: HostFile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saved)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: [.atomic])
        #endif
    }
}

/// A stable sibling lock spans each synchronous host/token operation across
/// store instances and processes. Atomic metadata replacement keeps this inode.
/// Readers defer recovery while a live writer owns it; writers report busy.
private final class HostCredentialFileLock {
    private let descriptor: Int32

    init?(_ metadataURL: URL) throws {
        let url = metadataURL.resolvingSymlinksInPath().appendingPathExtension("credential-lock")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        #if os(iOS)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch {
            close(fd)
            throw error
        }
        #endif
        descriptor = fd
    }

    deinit { close(descriptor) }
}
