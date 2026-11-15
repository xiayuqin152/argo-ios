import Foundation

public enum GatewayTransport: String, Codable, CaseIterable, Sendable {
    case direct, tailcat
}

/// An explicit credential delivery envelope. Never put this in host defaults,
/// diagnostic descriptions or URLs: address contains the Tailcat PSK.
public struct TailcatCode: Decodable, Sendable {
    public static let prefix = "argotc1:"
    public let address: String
    public let host: String
    public let port: Int
    public let fingerprint: String
    public let pair: String?

    public init(parsing text: String) throws {
        let bad = LoomError.message("Tailcat 连接码无效，请完整复制 \(RemoteHint.command("pair --transport tailcat")) 或 \(RemoteHint.command("tailcat code")) 的连接码。")
        guard text.utf8.count <= 65536,
              let word = text.split(whereSeparator: { $0.isWhitespace || $0 == "\"" || $0 == "'" }).first(where: { $0.hasPrefix(Self.prefix) }),
              let data = Base64URL.decode(String(word.dropFirst(Self.prefix.count))),
              let c = try? JSONDecoder().decode(Self.self, from: data),
              Self.validAddress(c.address), PairingCode.validHost(c.host), (1...65535).contains(c.port),
              let fp = Base64URL.decode(c.fingerprint), fp.count == 32 else { throw bad }
        if let pair = c.pair {
            guard let p = try? PairingCode(parsing: pair), p.host == c.host, p.port == c.port,
                  Fingerprint.matches(digest: p.fingerprint, expected: fp) else { throw bad }
        }
        self = c
    }

    public static func validAddress(_ address: String) -> Bool {
        // The official address is opaque CBOR/base64url prefixed tc. Parsing
        // and the mandatory nonzero PSK are enforced by the pinned helper.
        address.hasPrefix("tc") && address.count > 20 && address.count <= 32768 &&
            address.range(of: #"^tc[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil
    }

    public func validateSwitch(to host: LoomHost) throws {
        guard let pin = host.fingerprintData, let incoming = Base64URL.decode(fingerprint),
              Fingerprint.matches(digest: pin, expected: incoming), port == host.gatewayPort else {
            throw LoomError.message("Tailcat 连接码属于另一网关或端口。请在这台远程执行 argo tailcat code；证书变化请重新配对。")
        }
    }
}
