import Foundation

public enum HostRuntimeKind: String, Codable, Sendable, Hashable {
    /// The existing paired gateway/dev-machine runtime.
    case remote
    /// Argo's app-owned local loomd on this Mac.
    case local
}

/// A saved host: either a paired dev machine or the app-owned local runtime.
/// The remote device token is not here; it lives in the keychain.
public struct LoomHost: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// Gateway host name or IP address, from the pairing code.
    public var address = ""
    public var gatewayPort = LoomHost.defaultGatewayPort
    /// SHA-256 of the gateway certificate, base64url. A different certificate
    /// is refused until the host is paired again.
    public var fingerprint = ""
    /// The device id the gateway issued at pairing.
    public var deviceID = ""
    /// The local HTTP port. It stays the same for a host so the page origin
    /// (http://127.0.0.1:<port>), its cookie and its saved layout stay the same.
    /// 0 until the first connection picks one.
    public var localPort = 0
    /// The local SOCKS5 port browser tabs use to reach the web through the
    /// dev machine; fixed per host like localPort. 0 until first picked.
    public var socksPort = 0
    /// Browser tabs egress through the dev-machine gateway's SOCKS listener.
    /// Off means the user explicitly chose the Mac's own network.
    public var browserViaDevMachine = true
    /// Push the bundled loomd when the dev machine runs another version.
    public var autoInstall = true
    /// D50 Q2: this dev machine may offer Argo app updates to this Mac. Off by
    /// default: one window keeps every saved host connected, and a package
    /// from any of them runs as the user here.
    public var providesAppUpdates = false
    /// The ssh target of a host saved before v1.14; such a host has to be
    /// paired before it can connect. Empty for paired hosts.
    public var target = ""
    public var transport: GatewayTransport = .direct
    /// Explicit runtime kind; old saved hosts decode as remote.
    public var runtime: HostRuntimeKind = .remote

    public static let defaultGatewayPort = 6779

    public init(name: String, address: String, gatewayPort: Int, fingerprint: String, deviceID: String,
                runtime: HostRuntimeKind = .remote) {
        self.name = name
        self.address = address
        self.gatewayPort = gatewayPort
        self.fingerprint = fingerprint
        self.deviceID = deviceID
        self.runtime = runtime
    }

    /// A local host has no gateway certificate, pairing token or SSH target.
    public static func local(id: UUID = UUID(), name: String = "本地") -> LoomHost {
        var host = LoomHost(name: name, address: "", gatewayPort: 0,
                            fingerprint: "", deviceID: "", runtime: .local)
        host.id = id
        host.browserViaDevMachine = false
        return host
    }


    public var isLocal: Bool { runtime == .local }

    /// Whether the update check may ask this host for an Argo package: a
    /// remote host the user allowed (D50 Q2). This Mac's own loomd never offers one.
    public var offersAppUpdates: Bool { !isLocal && providesAppUpdates }

    /// 「名称（网关标签）」: what a decision point (Mac capability card, update
    /// sheet) shows, so two hosts can be told apart (D50 Q6).
    public var labeledName: String { isLocal ? displayName : "\(displayName)（\(gatewayLabel)）" }

    public var displayName: String {
        if !name.isEmpty { return name }
        if isLocal { return "本地" }
        return address.isEmpty ? target : address
    }

    /// Whether the host has gateway pairing data (older ssh hosts do not).
    public var isPaired: Bool {
        guard !isLocal else { return false }
        return !address.isEmpty && !fingerprint.isEmpty && !deviceID.isEmpty
    }

    /// The pinned certificate digest, nil when not paired or malformed.
    public var fingerprintData: Data? {
        guard let d = Base64URL.decode(fingerprint), d.count == 32 else { return nil }
        return d
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, gatewayPort, fingerprint, deviceID, localPort, socksPort, browserViaDevMachine, autoInstall, providesAppUpdates, target, transport, runtime
    }

    // Hosts saved by older versions lack the newer keys; they get the defaults
    // instead of failing to decode (which would drop every saved host).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        gatewayPort = try c.decodeIfPresent(Int.self, forKey: .gatewayPort) ?? Self.defaultGatewayPort
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 0
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? 0
        browserViaDevMachine = try c.decodeIfPresent(Bool.self, forKey: .browserViaDevMachine) ?? true
        autoInstall = try c.decodeIfPresent(Bool.self, forKey: .autoInstall) ?? true
        providesAppUpdates = try c.decodeIfPresent(Bool.self, forKey: .providesAppUpdates) ?? false
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
        transport = try c.decodeIfPresent(GatewayTransport.self, forKey: .transport) ?? .direct
        runtime = try c.decodeIfPresent(HostRuntimeKind.self, forKey: .runtime) ?? .remote
    }
}

public enum LoomError: LocalizedError, Equatable {
    case message(String)
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

extension LoomError {
    /// loomd's error body {error, detail, code} (err_proto) as one message:
    /// the Chinese summary, then loomd's original text on its own line, so the
    /// shell still shows everything the former single `error` string carried.
    public static func responseMessage(_ data: Data, fallback: String) -> String {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summary = body["error"] as? String, !summary.isEmpty else { return fallback }
        if let detail = body["detail"] as? String, !detail.isEmpty, detail != summary { return summary + "\n" + detail }
        return summary
    }
}

extension LoomHost {
    /// A paired host's gateway fields; every one of them came from a pairing
    /// code or the gateway and is checked again before it is saved or used.
    public func validate() throws {
        if isLocal { return }
        guard isPaired else {
            throw LoomError.message("这台远程还没有配对。请在远程上执行 \(RemoteHint.command("pair"))，再把配对码粘贴到 Argo。")
        }
        guard PairingCode.validHost(address) else { throw LoomError.message("远程地址「\(address.prefix(80))」不合法") }
        guard (1...65535).contains(gatewayPort) else { throw LoomError.message("网关端口要在 1 到 65535 之间") }
        guard fingerprintData != nil else { throw LoomError.message("证书指纹不合法，请重新配对") }
        guard GatewayCredential.validDevice(deviceID) else { throw LoomError.message("设备 id 不合法，请重新配对") }
    }

    /// `address:port`, IPv6 in brackets.
    public var gatewayLabel: String {
        if isLocal { return "本地" }
        return address.contains(":") ? "[\(address)]:\(gatewayPort)" : "\(address):\(gatewayPort)"
    }
}

/// D50 Q6: no two saved hosts show the same name. Mac capability cards,
/// notifications and the update sheet name the host they are about; with two
/// hosts called the same the user could not tell which one is asking.
public enum HostNames {
    static func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// Another saved host showing the same name (case and surrounding space ignored).
    public static func clash(_ host: LoomHost, in hosts: [LoomHost]) -> LoomHost? {
        let name = key(host.displayName)
        guard !name.isEmpty else { return nil }
        return hosts.first { $0.id != host.id && key($0.displayName) == name }
    }

    public static func clashMessage(_ name: String) -> String {
        "已有一台名为「\(name)」的远程。请换一个名称，免得 Mac 能力卡片、通知和更新提示分不清是哪一台。"
    }
}

/// Stable local identity helpers. The caller owns persistence; this keeps the
/// same UUID across launches/windows/layout/browser-profile/notification
/// lookups instead of inventing a second local id.
public enum LocalHostIdentity {
    public static func local(in hosts: [LoomHost]) -> LoomHost? {
        hosts.first { $0.isLocal }
    }

    /// Returns the existing local host, or inserts one at the front. `created`
    /// is true only on first creation.
    @discardableResult
    public static func ensureLocal(in hosts: inout [LoomHost],
                                    makeID: () -> UUID = { UUID() }) -> (host: LoomHost, created: Bool) {
        if let existing = local(in: hosts) { return (existing, false) }
        let host = LoomHost.local(id: makeID())
        hosts.insert(host, at: 0)
        return (host, true)
    }
}
