import Foundation

/// Where device tokens live: the Keychain on the phone (LoomKit's
/// DeviceTokenStore), memory in tests and previews.
public protocol DeviceTokenStoring: Sendable {
    func save(_ token: String, for host: UUID) throws
    /// nil when there is no (valid) token; other failures throw.
    func read(_ host: UUID) throws -> String?
    func delete(_ host: UUID) throws
}

#if canImport(Security)
/// The device tokens as generic passwords readable after the first unlock
/// and never synced (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
/// exactly as the Mac stores them.
public struct KeychainDeviceTokens: DeviceTokenStoring {
    public init() {}
    public func save(_ token: String, for host: UUID) throws { try DeviceTokenStore.save(token, for: host) }
    public func read(_ host: UUID) throws -> String? { try DeviceTokenStore.read(host) }
    public func delete(_ host: UUID) throws { try DeviceTokenStore.deleteChecked(host) }
}
#endif

public final class InMemoryDeviceTokens: DeviceTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [UUID: String] = [:]

    public init() {}

    public func save(_ token: String, for host: UUID) throws {
        guard GatewayCredential.validToken(token) else { throw LoomError.message("内部错误：设备凭据格式不对") }
        lock.lock(); defer { lock.unlock() }
        tokens[host] = token
    }

    public func read(_ host: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return tokens[host]
    }

    public func delete(_ host: UUID) {
        lock.lock(); defer { lock.unlock() }
        tokens[host] = nil
    }
}
