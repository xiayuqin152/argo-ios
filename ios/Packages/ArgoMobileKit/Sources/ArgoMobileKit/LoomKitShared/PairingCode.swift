import Foundation

/// The code `argo pair` prints (api.md v1.14):
/// `argo1:<host>:<port>:<certificate SHA-256, base64url>:<one-time secret, base64url, 128 bit>`.
/// It is valid for 10 minutes and once only; the dev machine checks that.
public struct PairingCode: Equatable, Sendable {
    public static let prefix = "argo1:"
    /// What a remote still running Argo 1.0.9 prints. A new Argo pairs with
    /// such a remote before it can push the upgrade (pairing is what lets it
    /// connect at all), so parsing reads both prefixes; this is the only place.
    public static let legacyPrefix = "loom1:"

    /// Host name or IP address of the gateway (IPv6 without brackets).
    public var host: String
    public var port: Int
    /// SHA-256 of the gateway certificate (DER), 32 bytes.
    public var fingerprint: Data
    /// The one-time secret, as printed (base64url); sent back verbatim.
    public var secret: String

    /// Whether `text` holds a pairing code of either prefix (clipboard and QR
    /// scanning use it to tell a code from other text).
    public static func appearsIn(_ text: String) -> Bool {
        text.contains(prefix) || text.contains(legacyPrefix)
    }

    /// Parses a code; surrounding text is allowed (a terminal line copied
    /// with its prompt), the first word starting with `argo1:` (or the older
    /// `loom1:`) is used.
    public init(parsing text: String) throws {
        guard let word = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
            .first(where: { $0.hasPrefix(Self.prefix) || $0.hasPrefix(Self.legacyPrefix) }) else {
            throw LoomError.message("没有找到配对码。配对码以 argo1: 开头（旧版远程是 loom1:），请在远程上执行 \(RemoteHint.command("pair")) 获取。")
        }
        // Both prefixes have the same length.
        let parts = word.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        // The host may be an IPv6 address with colons; the other fields have none.
        guard parts.count >= 4 else { throw Self.malformed }
        let secret = String(parts[parts.count - 1])
        let print = String(parts[parts.count - 2])
        let portText = String(parts[parts.count - 3])
        var host = parts[0..<(parts.count - 3)].joined(separator: ":")
        host = Self.normalizedHost(host)
        guard Self.validHost(host) else {
            throw LoomError.message("配对码里的远程地址「\(host.prefix(80))」不合法")
        }
        guard !portText.isEmpty, portText.count <= 5, portText.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(portText), (1...65535).contains(port) else {
            throw LoomError.message("配对码里的端口不合法")
        }
        guard let fingerprint = Base64URL.decode(print), fingerprint.count == 32 else {
            throw LoomError.message("配对码里的证书指纹不合法（应为 SHA-256）")
        }
        guard let raw = Base64URL.decode(secret), raw.count == 16 else {
            throw LoomError.message("配对码里的一次性密钥不合法（应为 128 位）")
        }
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        self.secret = secret
    }

    private static let malformed = LoomError.message("配对码格式不对，应为 argo1:<地址>:<端口>:<指纹>:<密钥>（旧版远程是 loom1:）。请完整复制 pair 命令打印的那一行。")

    /// Pairing codes and saved hosts contain raw addresses, not URI hosts:
    /// brackets delimit IPv6, and `%25en0` means the literal zone `25en0`.
    /// Unicode DNS follows Go's pipeline: NFC, Unicode lowercase, then
    /// UTS #46 non-transitional lookup via Foundation to standard A-labels.
    /// ASCII names retain their spelling.
    static func normalizedHost(_ host: String) -> String {
        var host = host
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if !host.contains(":"), host.unicodeScalars.contains(where: { !$0.isASCII }) {
            host = host.precomposedStringWithCanonicalMapping.lowercased()
            var components = URLComponents()
            components.scheme = "http"
            components.host = host
            let prefix = "http://"
            if let serialized = components.string, serialized.hasPrefix(prefix) {
                host = String(serialized.dropFirst(prefix.count))
            }
        }
        return host
    }

    /// DNS names and hexadecimal IP digits are case-insensitive, but an IPv6
    /// zone is a case-sensitive interface name or index on the connecting device.
    public static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = zoneSplit(normalizedHost(lhs))
        let rhs = zoneSplit(normalizedHost(rhs))
        return lhs.host.caseInsensitiveCompare(rhs.host) == .orderedSame && lhs.zone == rhs.zone
    }

    private static func zoneSplit(_ host: String) -> (host: String, zone: String?) {
        guard let percent = host.firstIndex(of: "%") else { return (host, nil) }
        return (String(host[..<percent]), String(host[host.index(after: percent)...]))
    }

    /// A DNS name, an IPv4 address or an IPv6 address: only the characters
    /// those use, so the value is safe to show and to hand to Network.framework.
    public static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"), !host.hasPrefix(".") else { return false }
        if host.contains(":") {
            return host.range(of: #"^[0-9A-Fa-f:.]+(%[A-Za-z0-9]+)?\z"#, options: .regularExpression) != nil
        }
        return host.range(of: #"^[A-Za-z0-9.-]+\z"#, options: .regularExpression) != nil
    }
}

/// Base64url (RFC 4648 §5), padding optional.
public enum Base64URL {
    public static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.range(of: #"^[A-Za-z0-9_-]+={0,2}\z"#, options: .regularExpression) != nil else { return nil }
        var s = text.replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if s.count % 4 == 1 { return nil }
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Certificate pinning: the gateway's certificate is trusted only when its
/// SHA-256 equals the fingerprint saved at pairing.
public enum Fingerprint {
    /// Compares in constant time; a wrong length never matches.
    public static func matches(digest: Data, expected: Data) -> Bool {
        guard digest.count == 32, expected.count == 32 else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(digest, expected) { diff |= a ^ b }
        return diff == 0
    }

    /// `AB:CD:…` of the first 8 bytes, for showing the user which certificate a host has.
    public static func short(_ data: Data) -> String {
        data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
