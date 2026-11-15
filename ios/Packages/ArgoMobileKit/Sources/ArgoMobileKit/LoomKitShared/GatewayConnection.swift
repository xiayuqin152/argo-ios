#if canImport(Network)
import CryptoKit
import Foundation
import Network
import Security

/// Where a gateway is and which certificate it must present.
public struct GatewayEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    /// SHA-256 of the certificate (DER) saved at pairing.
    public var fingerprint: Data

    public init(host: String, port: Int, fingerprint: Data) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
    }

    public init(_ host: LoomHost) throws {
        try host.validate()
        guard let print = host.fingerprintData else { throw GatewayError.fingerprintChanged }
        self.init(host: PairingCode.normalizedHost(host.address), port: host.gatewayPort, fingerprint: print)
    }

    public init(_ code: PairingCode) {
        self.init(host: code.host, port: code.port, fingerprint: code.fingerprint)
    }

    var nwEndpoint: NWEndpoint {
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 6779)
    }
}

enum GatewayTLS {
    /// TCP options for every gateway stream (control, HTTP, SOCKS, channels,
    /// warm pool).
    static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        // A stream that died with the network must be noticed in about a
        // minute rather than the Darwin default of roughly ten: three probes
        // ten seconds apart after thirty idle seconds, and a connection with
        // unacknowledged retransmissions is dropped after thirty more.
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 30
        return tcp
    }

    /// TLS 1.3 only, trusting exactly the pinned certificate: the system
    /// trust store plays no part (the certificate is self-signed), the
    /// leaf's SHA-256 must equal the saved fingerprint, and anything else is
    /// refused during the handshake. A mismatch raises `mismatch`.
    static func parameters(fingerprint: Data, mismatch: Flag, queue: DispatchQueue) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv13)
        sec_protocol_options_set_tls_resumption_enabled(sec, true)
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            complete(GatewayTLS.verify(trust, fingerprint: fingerprint, mismatch: mismatch))
        }, queue)
        let params = NWParameters(tls: tls, tcp: tcpOptions())
        // The dev machine is reached directly, like Orca's pairing; a system
        // proxy must not sit between the Mac and the pinned gateway.
        params.preferNoProxies = true
        return params
    }

    static func verify(_ trust: sec_trust_t, fingerprint: Data, mismatch: Flag) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate], let leaf = chain.first else {
            mismatch.raise()
            return false
        }
        let der = SecCertificateCopyData(leaf) as Data
        let ok = Fingerprint.matches(digest: Data(SHA256.hash(data: der)), expected: fingerprint)
        if !ok { mismatch.raise() }
        return ok
    }
}

/// TCP options for the loopback listeners that accept WKWebView, URLSession
/// and SOCKS connections.
enum LoopbackListener {
    /// Nagle off: a splice writes exactly what it just received, and with
    /// Nagle a small write waits for the previous one's ACK. On loopback that
    /// shows up as 40–100 ms steps in streamed terminal and Agent output
    /// instead of an even flow.
    static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return tcp
    }

    static func parameters(port: NWEndpoint.Port) -> NWParameters {
        let params = NWParameters(tls: nil, tcp: tcpOptions())
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        params.requiredInterfaceType = .loopback
        params.allowLocalEndpointReuse = true
        params.preferNoProxies = true
        return params
    }
}

/// Text for a connection failure; a close during the handshake carries
/// GatewayHandshake.closedHint.
func describe(_ error: NWError) -> String {
    switch error {
    case .posix(let code):
        switch code {
        case .ECONNREFUSED: return "远程拒绝连接（Argo 没在运行？在远程上执行 \(RemoteHint.command("serve --daemon"))，或 \(RemoteHint.command("autostart enable"))）"
        case .ETIMEDOUT: return PairingReachability.connectTimedOut
        case .EHOSTUNREACH, .ENETUNREACH: return PairingReachability.networkUnreachable
        case .ECONNRESET: return "连接在握手时被重置（\(GatewayHandshake.closedHint)）"
        default: return String(cString: strerror(code.rawValue))
        }
    case .dns(let code): return "无法解析远程地址（DNS 错误 \(code)）"
    case .tls(let status):
        // errSSLClosedGraceful / errSSLClosedAbort: the far end hung up mid-handshake.
        if GatewayHandshake.isClosed(tlsStatus: status) { return "TLS 握手时连接被关闭（\(status)；\(GatewayHandshake.closedHint)）" }
        return "TLS 握手失败（\(status)）"
    default: return "\(error)"
    }
}

extension NWError {
    /// The gateway (or something in between) hung up during the handshake.
    var closedInHandshake: Bool {
        switch self {
        case .posix(let code): return GatewayHandshake.isClosed(posix: code.rawValue)
        case .tls(let status): return GatewayHandshake.isClosed(tlsStatus: status)
        default: return false
        }
    }
}

/// A stream whose header was accepted.
struct OpenedStream {
    let connection: NWConnection
    let reply: GatewayReply
    /// Bytes that came after the reply line: the start of the raw stream.
    let rest: Data
}

/// Reads one line on the connection queue. Its owner bounds the whole request;
/// there is no separate first-reply deadline for an upgrade upload.
final class LineReader: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer: LineBuffer
    private let done: (Result<(Data, Data), GatewayError>) -> Void
    private let closedError: () -> GatewayError
    private var finished = false
    private var ended = false

    init(_ connection: NWConnection, buffer: LineBuffer = LineBuffer(max: GatewayHeader.maxLine),
         closedError: @escaping () -> GatewayError,
         done: @escaping (Result<(Data, Data), GatewayError>) -> Void) {
        self.connection = connection
        self.buffer = buffer
        self.closedError = closedError
        self.done = done
    }

    func start() { step() }

    private func step() {
        switch buffer.next() {
        case .line(let line):
            finish(.success((line, buffer.takeRest())))
        case .tooLong:
            finish(.failure(.protocolError("网关的回复过长")))
        case .needMore:
            if ended {
                finish(.failure(closedError()))
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
                guard !finished else { return }
                if let data { buffer.append(data) }
                if isComplete || error != nil { ended = true }
                step()
            }
        }
    }

    private func finish(_ result: Result<(Data, Data), GatewayError>) {
        guard !finished else { return }
        finished = true
        done(result)
    }
}

/// Establishes pinned TLS only. `upgrade` must send its body before waiting
/// for a result; the ordinary StreamOpener adds a header/reply exchange.
final class GatewayConnector: @unchecked Sendable {
    private var connection: NWConnection?
    private var timer: DispatchWorkItem?
    private let mismatch = Flag()
    private var completion: ((Result<NWConnection, GatewayError>) -> Void)?

    static func connect(_ endpoint: GatewayEndpoint, queue: DispatchQueue, timeout: TimeInterval = 10,
                        completion: @escaping (Result<NWConnection, GatewayError>) -> Void) -> GatewayConnector {
        let connector = GatewayConnector(completion)
        connector.start(endpoint, queue: queue, timeout: timeout)
        return connector
    }

    private init(_ completion: @escaping (Result<NWConnection, GatewayError>) -> Void) {
        self.completion = completion
    }

    private func start(_ endpoint: GatewayEndpoint, queue: DispatchQueue, timeout: TimeInterval) {
        let conn = NWConnection(to: endpoint.nwEndpoint,
                                using: GatewayTLS.parameters(fingerprint: endpoint.fingerprint, mismatch: mismatch, queue: queue))
        connection = conn
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout("连接远程网关 \(endpoint.host):\(endpoint.port) 超时（\(Int(timeout)) 秒）")))
        }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        conn.stateUpdateHandler = { [self] state in
            switch state {
            case .ready: finish(.success(conn))
            case .waiting(let error), .failed(let error):
                if mismatch.value { finish(.failure(.fingerprintChanged)) }
                else if error.closedInHandshake { finish(.failure(.handshakeClosed(describe(error)))) }
                else { finish(.failure(.network(describe(error)))) }
            case .cancelled: finish(.failure(.network("连接已取消")))
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func cancel() { finish(.failure(.network("连接已取消"))) }

    private func finish(_ result: Result<NWConnection, GatewayError>) {
        guard let completion else { return }
        self.completion = nil
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        if case .failure = result { connection?.cancel() }
        connection = nil
        completion(result)
    }
}

/// Opens one gateway stream: TLS with the pinned certificate, the header
/// line, the reply line.
final class StreamOpener: @unchecked Sendable {
    private let endpoint: GatewayEndpoint
    private let headerLine: Data
    private let queue: DispatchQueue
    private let completion: (Result<OpenedStream, GatewayError>) -> Void
    private var connector: GatewayConnector?
    private var connection: NWConnection?
    private var finished = false
    private var timer: DispatchWorkItem?

    /// Opens a stream; `completion` runs once on `queue`. On failure the
    /// connection is cancelled; on success the caller owns it.
    @discardableResult
    static func open(_ endpoint: GatewayEndpoint, header: GatewayHeader, queue: DispatchQueue, timeout: TimeInterval = 10,
                     completion: @escaping (Result<OpenedStream, GatewayError>) -> Void) -> StreamOpener? {
        let line: Data
        do { line = try header.line() } catch {
            queue.async { completion(.failure(.protocolError("请求头无法编码"))) }
            return nil
        }
        let opener = StreamOpener(endpoint, line, queue, completion)
        opener.start(timeout: timeout)
        return opener
    }

    /// Called on the opening queue. Existing callers may leave ownership
    /// with the deadline; a cancelled mobile request releases it at once.
    func cancel() { finish(.failure(.network("连接已取消"))) }

    private init(_ endpoint: GatewayEndpoint, _ headerLine: Data, _ queue: DispatchQueue,
                 _ completion: @escaping (Result<OpenedStream, GatewayError>) -> Void) {
        self.endpoint = endpoint
        self.headerLine = headerLine
        self.queue = queue
        self.completion = completion
    }

    private func start(timeout: TimeInterval) {
        let timer = DispatchWorkItem { [weak self] in
            self?.finish(.failure(.timeout("连接远程网关 \(self?.endpoint.host ?? ""):\(self?.endpoint.port ?? 0) 超时（\(Int(timeout)) 秒）")))
        }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connector = GatewayConnector.connect(endpoint, queue: queue, timeout: timeout) { [self] result in
            guard !finished else {
                if case .success(let conn) = result { conn.cancel() }
                return
            }
            switch result {
            case .failure(let error): finish(.failure(error))
            case .success(let conn):
                connection = conn
                conn.send(content: headerLine, completion: .contentProcessed { [self] error in
                    guard !finished else { return }
                    if let error { finish(.failure(.network(describe(error)))) }
                    else { readReply(conn) }
                })
            }
        }
    }

    private func readReply(_ conn: NWConnection) {
        let reader = LineReader(conn, closedError: { .network("网关关闭了连接（Argo 版本可能不支持这个请求）") }) { [self] result in
            switch result {
            case .success(let (line, rest)):
                do {
                    let reply = try GatewayReply.parse(line)
                    if let error = reply.failure {
                        finish(.failure(error))
                    } else {
                        finish(.success(OpenedStream(connection: conn, reply: reply, rest: rest)))
                    }
                } catch let error as GatewayError {
                    finish(.failure(error))
                } catch {
                    finish(.failure(.protocolError(error.localizedDescription)))
                }
            case .failure(let error):
                finish(.failure(error))
            }
        }
        // The overall timer already bounds the wait.
        reader.start()
    }

    private func finish(_ result: Result<OpenedStream, GatewayError>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        connector?.cancel(); connector = nil
        if case .failure = result { connection?.cancel() }
        connection = nil
        completion(result)
    }
}

/// Copies bytes both ways between two connections on the same queue, with
/// backpressure (the next read waits for the previous write), forwarding
/// end-of-stream, and closing both when either fails or both ends finished.
final class Splice: @unchecked Sendable {
    let a: NWConnection
    let b: NWConnection
    private var open = 2
    private var closed = false
    var onClose: (() -> Void)?
    var transferred: ((Bool, Int) -> Void)?
    var filterAtoB: ((Data) throws -> Data)?
    var filterBtoA: ((Data, @escaping (Result<Data, Error>) -> Void) -> Void)?

    init(_ a: NWConnection, _ b: NWConnection) {
        self.a = a
        self.b = b
    }

    /// `toA` / `toB` are bytes already read that belong to the other side.
    func start(toA: Data = Data(), toB: Data = Data()) {
        for c in [a, b] {
            switch c.state {
            case .failed, .cancelled:
                close()
                return
            default:
                break
            }
            c.stateUpdateHandler = { [self] state in
                switch state {
                case .failed, .cancelled: close()
                default: break
                }
            }
        }
        filteredSend(toA, from: b, to: a) { [self] in pump(b, a) }
        filteredSend(toB, from: a, to: b) { [self] in pump(a, b) }
    }

    private func send(_ data: Data, to: NWConnection, then: @escaping () -> Void) {
        guard !data.isEmpty else { then(); return }
        to.send(content: data, completion: .contentProcessed { [self] error in
            if error != nil { close() } else { transferred?(to === a, data.count); then() }
        })
    }

    private func pump(_ from: NWConnection, _ to: NWConnection) {
        guard !closed else { return }
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            guard !closed else { return }
            let next = { [self] in
                if isComplete {
                    finishDirection(to)
                } else if error != nil {
                    close()
                } else {
                    pump(from, to)
                }
            }
            if let data, !data.isEmpty {
                filteredSend(data, from: from, to: to, then: next)
            } else {
                next()
            }
        }
    }

    private func filteredSend(_ data: Data, from: NWConnection, to: NWConnection, then: @escaping () -> Void) {
        if from === b, let filterBtoA, !data.isEmpty {
            filterBtoA(data) { [self] result in
                guard !closed else { return }
                switch result {
                case .success(let safe): send(safe, to: to, then: then)
                case .failure: close()
                }
            }
        } else if from === a, let filterAtoB, !data.isEmpty {
            do { send(try filterAtoB(data), to: to, then: then) } catch { close() }
        } else { send(data, to: to, then: then) }
    }

    private func finishDirection(_ to: NWConnection) {
        to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        open -= 1
        if open == 0 { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        a.cancel()
        b.cancel()
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }
}

/// Pairing (api.md v1.14): the one-time secret from the code buys a device
/// credential; the certificate must match the code's fingerprint.
public enum GatewayPairing {
    public static func pair(_ code: PairingCode, name: String, forwardedPort: Int? = nil) async throws -> GatewayCredential {
        let queue = DispatchQueue(label: "loom.gateway.pair")
        let opened: OpenedStream = try await withCheckedThrowingContinuation { continuation in
            let endpoint = forwardedPort.map { GatewayEndpoint(host: "127.0.0.1", port: $0, fingerprint: code.fingerprint) } ?? GatewayEndpoint(code)
            StreamOpener.open(endpoint, header: .pair(secret: code.secret, name: name), queue: queue, timeout: 15) {
                continuation.resume(with: $0.mapError { $0 as Error })
            }
        }
        opened.connection.cancel()
        guard let device = opened.reply.device, GatewayCredential.validDevice(device),
              let token = opened.reply.token, GatewayCredential.validToken(token) else {
            throw GatewayError.protocolError("网关返回的设备凭据格式不对（远程上的 Argo 版本可能不匹配）")
        }
        return GatewayCredential(device: device, token: token)
    }
}
#endif
