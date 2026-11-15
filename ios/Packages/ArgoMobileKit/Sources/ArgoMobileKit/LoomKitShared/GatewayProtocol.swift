import Foundation

// Wire format of the loomd gateway (api.md v1.14), as this client speaks it.
//
// Every logical stream is its own TLS 1.3 connection to <host>:<port>. The
// client first sends one header line (JSON object + "\n", at most 8 KiB):
//   {"v":1,"op":"pair","secret":"<from the pairing code>","name":"<Mac name>"}
//   {"v":1,"op":"<op>","device":"<id>","token":"<device token>", …op fields}
//     op http                       raw bytes to/from 127.0.0.1:3430
//     op http  "warm":true          the same, opened ahead of need: the gateway answers
//                                   at once and dials loomd when the first request
//                                   byte arrives (capability "http-warm"; a gateway
//                                   without it ignores the field and dials at once)
//     op token                      reply carries "token" (loomd's HTTP token)
//     op connect  "host","port"     raw bytes to/from host:port, dialled by the dev machine
//     op control                    NDJSON both ways (ControlMessage)
//     op attach   "stream"          raw bytes of the reverse stream announced by `open`
//     op upgrade  "sha256","size"   header, exactly `size` bytes, ONE final result;
//                                   read concurrently for an early rejection
// The gateway answers with one reply line (GatewayReply):
//   {"ok":true,…} then the stream as above, or {"ok":false,"error":"…","code":"…"}
//   and closes. Codes the client acts on: "auth" (device unknown or token
//   wrong: pair again), "pair" (pairing code expired, used or wrong),
//   "banned" (too many failures from this address), "refused" and
//   "unreachable" (connect target).
// Control messages from the gateway (internal/gateway/session.go): hello
// {version, commit, ptyd, arch, capabilities}, ping {t}, pong {t}, open
// {stream, channel}. From the client: hello {version, capabilities}, ping {t}
// every 15 s, pong {t}, open-failed {stream, error} for an `open` it will not
// serve.

public enum GatewayOp: String, Codable, Sendable {
    case pair, http, token, connect, control, attach, upgrade
}

/// The first line of every stream.
public struct GatewayHeader: Encodable, Equatable, Sendable {
    public var v = 1
    public var op: GatewayOp
    public var device: String?
    public var token: String?
    public var secret: String?
    public var name: String?
    public var host: String?
    public var port: Int?
    public var stream: String?
    public var sha256: String?
    public var size: Int64?
    public var force: Bool?
    /// op upgrade: the user confirmed replacing a strictly newer loomd on the
    /// dev machine (the gateway refuses without it).
    public var allowDowngrade: Bool?
    /// op upgrade: the running commit the user confirmed replacing with the
    /// same build number from another commit (IN-05). The gateway refuses
    /// unless it is still the running commit, so a push by another Mac
    /// between the question and the upload is not overwritten.
    public var replaceCommit: String?
    /// op upgrade (D68, gateway capability `upgrade-preflight`): the code a
    /// `ptyd_mismatch` refusal returned, after the user confirmed stranding
    /// exactly the terminals it listed.
    public var confirmTerminals: String?
    /// op http only: an idle stream the Mac keeps ready (WarmPool).
    public var warm: Bool?

    public static let maxLine = 8 * 1024

    public init(op: GatewayOp, credential: GatewayCredential) {
        self.op = op
        self.device = credential.device
        self.token = credential.token
    }

    /// An `http` stream opened ahead of need.
    public static func warmHTTP(credential: GatewayCredential) -> GatewayHeader {
        var header = GatewayHeader(op: .http, credential: credential)
        header.warm = true
        return header
    }

    public static func upgrade(credential: GatewayCredential, sha256: String, size: Int64,
                               force: Bool, allowDowngrade: Bool = false,
                               replaceCommit: String? = nil,
                               confirmTerminals: String? = nil) -> GatewayHeader {
        var header = GatewayHeader(op: .upgrade, credential: credential)
        header.sha256 = sha256
        header.size = size
        header.force = force
        if allowDowngrade { header.allowDowngrade = true }
        header.replaceCommit = replaceCommit
        header.confirmTerminals = confirmTerminals
        return header
    }

    public static func pair(secret: String, name: String) -> GatewayHeader {
        var h = GatewayHeader(op: .pair)
        h.secret = secret
        h.name = String(name.prefix(64))
        return h
    }

    private init(op: GatewayOp) { self.op = op }

    /// The JSON line, newline included. JSONEncoder escapes control
    /// characters, so a value can never end the line early.
    public func line() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        guard data.count < Self.maxLine else { throw GatewayError.protocolError("请求头过长") }
        data.append(0x0A)
        return data
    }
}

/// The device credential issued at pairing; the token lives in the keychain.
public struct GatewayCredential: Equatable, Sendable {
    public var device: String
    public var token: String

    public init(device: String, token: String) {
        self.device = device
        self.token = token
    }

    /// Device ids and tokens are opaque base64url / hex words from the
    /// gateway; anything else is refused before it is stored or sent.
    public static func validDevice(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_-]{1,64}\\z", options: .regularExpression) != nil
    }

    public static func validToken(_ s: String) -> Bool {
        s.range(of: "^[A-Za-z0-9_-]{32,128}\\z", options: .regularExpression) != nil
    }
}

/// The reply line.
public struct GatewayReply: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var code: String?
    public var device: String?
    public var token: String?
    public var version: String?
    public var commit: String?
    public var path: String?
    /// upgrade refused with `ptyd_mismatch` (D68): the live terminals the
    /// new loomd would strand, and the code that confirms exactly them.
    public var terminals: [StrandedTerminal]?
    public var confirm: String?

    public struct StrandedTerminal: Decodable, Equatable, Sendable {
        public var id: String
        public var title: String?
        public var cwd: String?

        public init(id: String, title: String? = nil, cwd: String? = nil) {
            self.id = id; self.title = title; self.cwd = cwd
        }

        /// How the terminal is named to the user: 「title」（cwd）.
        public var label: String {
            let name = (title?.isEmpty == false ? title : nil) ?? id
            if let cwd, !cwd.isEmpty { return "「\(name)」（\(cwd)）" }
            return "「\(name)」"
        }
    }

    public static func parse(_ line: Data) throws -> GatewayReply {
        do {
            return try JSONDecoder().decode(GatewayReply.self, from: line)
        } catch {
            throw GatewayError.protocolError("网关的回复不是合法的 JSON（远程上的 Argo 版本可能不匹配）")
        }
    }

    /// The error this reply stands for, nil when ok.
    public var failure: GatewayError? {
        if ok { return nil }
        let text = String((error ?? "").prefix(300))
        switch code {
        case "auth": return .unauthorized(text)
        case "pair": return .pairingRejected(text)
        case "banned": return .banned(text)
        case "refused": return .refused(text)
        case "unreachable": return .unreachable(text)
        case "ptyd_mismatch" where confirm?.isEmpty == false && terminals?.isEmpty == false:
            return .strandsTerminals(text, terminals: (terminals ?? []).map(\.label), confirm: confirm ?? "")
        default: return .rejected(text)
        }
    }
}

public enum GatewayError: LocalizedError, Equatable, Sendable {
    /// The certificate is not the one saved at pairing.
    case fingerprintChanged
    /// The device id or token was refused (revoked, or the dev machine was reset).
    case unauthorized(String)
    case pairingRejected(String)
    case banned(String)
    case refused(String)
    case unreachable(String)
    case rejected(String)
    case network(String)
    /// The gateway closed the connection during the TLS handshake
    /// (GatewayHandshake): banned address, too many pending connections, or
    /// something in between.
    case handshakeClosed(String)
    case timeout(String)
    case protocolError(String)
    case localPort(String)
    /// The new loomd would strand these live terminals (labels); retry the
    /// upgrade with `confirm` once the user agreed (D68).
    case strandsTerminals(String, terminals: [String], confirm: String)

    /// Errors that reconnecting cannot fix; the user has to pair again.
    public var isFatal: Bool {
        switch self {
        case .fingerprintChanged, .unauthorized: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .fingerprintChanged:
            return "远程证书变了，可能是重装或中间人，请重新配对。Argo 已停止连接这台远程。"
        case .unauthorized(let s):
            return "远程不再接受这台 Mac 的凭据（可能已被 argo devices revoke 撤销），请在远程上执行 \(RemoteHint.command("pair")) 后重新配对。" + Self.detail(s)
        case .pairingRejected(let s):
            return "配对失败：配对码已过期、已用过或不正确。请在远程上重新执行 \(RemoteHint.command("pair"))。" + Self.detail(s)
        case .banned(let s):
            return "这台 Mac 的地址失败次数过多，远程网关暂时拒绝连接（10 分钟后自动解除）。" + Self.detail(s)
        case .refused(let s): return "目标拒绝连接。" + Self.detail(s)
        case .unreachable(let s): return "目标不可达。" + Self.detail(s)
        case .rejected(let s): return s.isEmpty ? "网关拒绝了请求" : "网关拒绝了请求：\(s)"
        case .network(let s), .handshakeClosed(let s): return "连不上远程网关：\(s)"
        case .timeout(let s): return s
        case .protocolError(let s): return s
        case .localPort(let s): return s
        case .strandsTerminals(let s, _, _): return s
        }
    }

    private static func detail(_ s: String) -> String { s.isEmpty ? "" : "\n（\(s)）" }
}

/// What `control` carries after the reply.
public struct GatewayHello: Equatable, Sendable {
    public var version: String?
    public var commit: String?
    public var ptyd: Int?
    /// GOARCH of the dev machine (amd64, arm64).
    public var arch: String?
    /// Monotonic loomd build; absent on a loomd built before the field
    /// existed, which every comparison treats as 0.
    public var build: Int?
    public var capabilities: [String]
    /// loomd binaries the dev machine's supervisor rolled back (IN-06); the
    /// gateway refuses to install these again. Empty on an older loomd.
    public var api: Int?
    public var rolledBack: [RolledBackLoomd]

    public init(version: String?, commit: String?, ptyd: Int?, arch: String?, build: Int? = nil,
                capabilities: [String] = [], rolledBack: [RolledBackLoomd] = [], api: Int? = nil) {
        self.version = version
        self.commit = commit
        self.ptyd = ptyd
        self.arch = arch
        self.build = build
        self.capabilities = capabilities
        self.api = api
        self.rolledBack = rolledBack
    }

    /// Whether the gateway announced a capability (switch on these, not on versions).
    public func has(_ capability: String) -> Bool { capabilities.contains(capability) }
}

/// One entry of the hello's `rolledBack`: the binary's sha256 and why the
/// supervisor rolled it back (「没有在时限内通过健康检查」…).
public struct RolledBackLoomd: Equatable, Sendable {
    public var sha256: String
    public var reason: String

    public init(sha256: String, reason: String) {
        self.sha256 = sha256
        self.reason = reason
    }
}

public enum ControlMessage: Equatable, Sendable {
    case hello(GatewayHello)
    case ping(Int64)
    case pong(Int64)
    /// A reverse stream waits on the dev machine for an `attach`.
    case open(stream: String, channel: String)
    /// Types this client does not know (newer loomd); ignored.
    case other(String)

    private struct Raw: Decodable {
        var type: String
        /// ping/pong token (internal/gateway/session.go: the gateway sends
        /// unix ms and echoes whatever the Mac sent).
        var t: Int64?
        var version: String?
        var commit: String?
        var ptyd: Int?
        var arch: String?
        var build: Int?
        var capabilities: [String]?
        var api: Int?
        var rolledBack: [RawRolledBack]?
        var stream: String?
        var channel: String?
    }

    private struct RawRolledBack: Decodable {
        var sha256: String?
        var reason: String?
    }

    /// Parses one line; nil for a line that is not a JSON object with a
    /// string `type`, or whose fields are out of bounds.
    public static func parse(_ line: Data) -> ControlMessage? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: line) else { return nil }
        switch raw.type {
        case "hello":
            return .hello(GatewayHello(
                version: raw.version.map { String($0.prefix(64)) },
                commit: raw.commit.map { String($0.prefix(64)) },
                ptyd: raw.ptyd,
                arch: raw.arch.map { String($0.prefix(32)) },
                build: raw.build.map { max(0, $0) },
                capabilities: (raw.capabilities ?? []).prefix(64).map { String($0.prefix(64)) },
                rolledBack: (raw.rolledBack ?? []).prefix(16).compactMap { entry in
                    guard let sha = entry.sha256?.lowercased(), isHex64(sha) else { return nil }
                    return RolledBackLoomd(sha256: sha, reason: String((entry.reason ?? "").prefix(300)))
                }, api: raw.api.map { max(0, $0) }))
        case "ping": return raw.t.map(ControlMessage.ping)
        case "pong": return raw.t.map(ControlMessage.pong)
        case "open":
            guard let stream = raw.stream, let channel = raw.channel,
                  validName(stream, max: 128), validName(channel, max: 64) else { return nil }
            return .open(stream: stream, channel: channel)
        default:
            return .other(String(raw.type.prefix(64)))
        }
    }

    public static func validName(_ s: String, max: Int) -> Bool {
        !s.isEmpty && s.count <= max && s.range(of: "^[A-Za-z0-9._-]+\\z", options: .regularExpression) != nil
    }

    /// Lines the client sends.
    public static func ping(id: Int64) -> Data { line(["type": "ping", "t": id]) }
    public static func pong(id: Int64) -> Data { line(["type": "pong", "t": id]) }
    /// A reverse stream this Mac will not attach; the gateway fails the
    /// waiting `loomd channel` connection with `error` at once.
    public static func refuse(stream: String, reason: String) -> Data {
        line(["type": "open-failed", "stream": stream, "error": String(reason.prefix(200))])
    }
    /// The Mac's hello on a new control stream (`loomd devices list` shows the
    /// version), with the record of the last drop when one is owed (UD-08).
    public static func clientHello(version: String, capabilities: [String] = [],
                                   lastDisconnect: DisconnectTracker.Report? = nil) -> Data {
        var m: [String: Any] = ["type": "hello", "version": String(version.prefix(64)), "capabilities": capabilities]
        if let lastDisconnect { m["lastDisconnect"] = lastDisconnect.json }
        return line(m)
    }

    static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }
}

/// A lowercase SHA-256 hex digest (loomd binaries, the hello's rolledBack).
func isHex64(_ s: String) -> Bool {
    s.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil
}

/// Splits a byte stream into lines, refusing lines longer than `max`.
public struct LineBuffer: Sendable {
    public let max: Int
    private var pending = Data()

    public init(max: Int) { self.max = max }

    public enum Next: Equatable {
        case line(Data)
        case needMore
        case tooLong
    }

    public mutating func append(_ data: Data) { pending.append(data) }

    /// The next complete line (without "\n"), if any.
    public mutating func next() -> Next {
        if let nl = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex..<nl])
            pending = Data(pending[pending.index(after: nl)...])
            if line.count > max { return .tooLong }
            return .line(line)
        }
        return pending.count > max ? .tooLong : .needMore
    }

    /// Bytes after the last returned line (the start of a raw stream).
    public mutating func takeRest() -> Data {
        defer { pending = Data() }
        return pending
    }
}

/// Where a reverse channel lands on the Mac. Only loopback: the dev machine
/// names a channel, never an address, and a channel can only reach a
/// service on this Mac (api.md v1.14 「Mac 侧目标是本地 host:port」).
public struct ChannelTarget: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let unixPath: String?

    public init(unix: String) throws {
        guard unix == "/var/run/usbmuxd" else { throw LoomError.message("只允许 usbmuxd 系统 socket") }
        self.host = ""; self.port = 0; self.unixPath = unix
    }

    public init(host: String, port: Int) throws {
        guard Self.isLoopback(host) else {
            throw LoomError.message("通道目标只能是本地地址（127.0.0.1、::1 或 localhost），不能是 \(host.prefix(80))")
        }
        guard (1...65535).contains(port) else { throw LoomError.message("通道端口要在 1 到 65535 之间") }
        self.host = host
        self.port = port
        self.unixPath = nil
    }

    public static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy { $0.isASCII && $0.isNumber } && Int(p).map { (0...255).contains($0) } == true }
    }
}
