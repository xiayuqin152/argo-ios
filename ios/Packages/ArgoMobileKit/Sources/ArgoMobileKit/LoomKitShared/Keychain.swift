#if canImport(Security)
import Foundation
import Security

/// The gateway device tokens, one generic password per saved host in the
/// login keychain (api.md v1.14: 「token 在钥匙串」). Readable after the first
/// unlock so a reconnect after wake works with the screen locked; never
/// synced to other devices.
public enum DeviceTokenStore {
    public static let service = "dev.loom.Loom.gateway"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// Stores (or replaces) the token for a host.
    public static func save(_ token: String, for id: UUID) throws {
        guard GatewayCredential.validToken(token) else { throw LoomError.message("内部错误：设备凭据格式不对") }
        let data = Data(token.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Argo 远程凭据"
            add[kSecAttrDescription as String] = "Argo 网关设备凭据"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw LoomError.message("无法把设备凭据存进钥匙串：\(describe(status))")
        }
    }

    /// The token, nil when there is none; other keychain failures throw.
    public static func read(_ id: UUID) throws -> String? {
        let (status, data) = fetch(id, interactive: true)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else {
            throw LoomError.message("无法从钥匙串读取设备凭据：\(describe(status))")
        }
        return validToken(data)
    }

    /// Whether the token is readable right now without any keychain UI. A
    /// locked keychain or an authorization prompt comes back as `unavailable`
    /// instead of showing a dialog, so launch can read every host quietly.
    public static func access(_ id: UUID) -> TokenAccess {
        let (status, data) = fetch(id, interactive: false)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data else { return .unavailable(reason: describe(status)) }
        return validToken(data) == nil ? .missing : .available
    }

    private static func fetch(_ id: UUID, interactive: Bool) -> (OSStatus, Data?) {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        return (status, item as? Data)
    }

    private static func validToken(_ data: Data) -> String? {
        let token = String(decoding: data, as: UTF8.self)
        return GatewayCredential.validToken(token) ? token : nil
    }

    public static func delete(_ id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }

    /// An explicit removal that lets a caller retain its retry UI on failure.
    /// Existing Mac callers keep the nonthrowing delete operation above.
    public static func deleteChecked(_ id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "Keychain deletion failed (OSStatus \(status)): \(describe(status))",
            ])
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
#endif
