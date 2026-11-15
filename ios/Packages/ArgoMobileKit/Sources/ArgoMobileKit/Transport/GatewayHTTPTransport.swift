#if canImport(Network)
import Foundation
import Network

/// loomd HTTP over the dev machine's gateway, the way the Mac's Tunnel reaches
/// it but without a loopback listener: every request runs on an `http`
/// stream opened by LoomKit's StreamOpener (TLS 1.3, the certificate pinned
/// at pairing, the device credential in the header line). Idempotent
/// requests may reuse an idle stream; anything that changes state always gets
/// a fresh one, so a failure says unambiguously whether it was sent.
public final class GatewayHTTPTransport: ArgoHTTPTransport, @unchecked Sendable {
    /// One request from the first written byte to the end of its reply.
    public static let requestTimeout: TimeInterval = 30
    /// The gateway stream open (TCP, TLS, header and reply line).
    public static let openTimeout: TimeInterval = 10
    /// How long an idle stream is kept, and how many.
    public static let idleLimit: TimeInterval = 20
    public static let maxIdle = 2

    private let endpoint: GatewayEndpoint
    private let credential: GatewayCredential
    private let queue = DispatchQueue(label: "argo.mobile.gateway-http")

    // Only touched on `queue`.
    private var closed = false
    private var idle: [(connection: NWConnection, since: DispatchTime)] = []
    private var exchanges: [ObjectIdentifier: HTTPExchange] = [:]
    /// Streams being opened; a close or cancellation releases them at once.
    private var opening: [Int: PendingOpen] = [:]
    private var nextOpen = 0

    public init(endpoint: GatewayEndpoint, credential: GatewayCredential) {
        self.endpoint = endpoint
        self.credential = credential
    }

    public convenience init(host: LoomHost, credential: GatewayCredential) throws {
        self.init(endpoint: try GatewayEndpoint(host), credential: credential)
    }

    public func loomdToken() async throws -> String {
        let opened = try await open(GatewayHeader(op: .token, credential: credential))
        opened.connection.cancel()
        guard let token = opened.reply.token, token.range(of: "^[0-9a-f]{64}\\z", options: .regularExpression) != nil else {
            throw TransportFailure.open(.protocolError("网关返回的访问口令格式不对（应为 64 位十六进制）"))
        }
        return token
    }

    public func send(_ request: HTTPRequest, reuse: Bool, timeout requestTimeout: TimeInterval? = nil) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let timeout = requestTimeout ?? Self.requestTimeout
        guard timeout.isFinite, timeout > 0 else { throw HTTPError.invalidRequest("请求超时不合法") }
        let keep = reuse && request.idempotent
        let bytes = try request.encoded(keepAlive: keep)
        if keep, let connection = queue.sync(execute: takeIdle) {
            do {
                return try await exchange(connection, bytes, request: request, keep: keep, reused: true, timeout: timeout)
            } catch ExchangeRetry.staleIdle {
                // The idle stream had closed before it carried this GET; GET
                // changes nothing, so it goes once more on a fresh stream.
            }
        }
        let opened = try await open(GatewayHeader(op: .http, credential: credential))
        guard opened.rest.isEmpty else {
            opened.connection.cancel()
            throw TransportFailure.open(.protocolError("网关在请求之前发来了数据"))
        }
        return try await exchange(opened.connection, bytes, request: request, keep: keep, reused: false, timeout: timeout)
    }

    public func close() async {
        queue.sync {
            closed = true
            for entry in idle { entry.connection.cancel() }
            idle.removeAll()
            for exchange in exchanges.values { exchange.cancel() }
            exchanges.removeAll()
            for pending in opening.values { pending.abandon() }
            opening.removeAll()
        }
    }

    // MARK: Streams

    private func takeIdle() -> NWConnection? {
        let now = DispatchTime.now()
        while let entry = idle.popLast() {
            let age = Double(now.uptimeNanoseconds - entry.since.uptimeNanoseconds) / 1e9
            if age < Self.idleLimit, entry.connection.state == .ready { return entry.connection }
            entry.connection.cancel()
        }
        return nil
    }

    private func putIdle(_ connection: NWConnection) {
        guard !closed, idle.count < Self.maxIdle, connection.state == .ready else {
            connection.cancel()
            return
        }
        // A stream that ends while idle is dropped at once.
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.idle.removeAll { $0.connection === connection }
            default: break
            }
        }
        idle.append((connection, .now()))
    }

    /// Opens one stream; cancellation or close also cancels its handshake.
    private func open(_ header: GatewayHeader) async throws -> OpenedStream {
        try Task.checkCancellation()
        let pending = PendingOpen()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OpenedStream, Error>) in
                queue.async { [self] in
                    guard !closed else { continuation.resume(throwing: TransportFailure.closed); return }
                    guard pending.arm(continuation) else { return }
                    let id = nextOpen
                    nextOpen += 1
                    opening[id] = pending
                    pending.opener = StreamOpener.open(endpoint, header: header, queue: queue, timeout: Self.openTimeout) { [self] result in
                        opening[id] = nil
                        pending.land(result)
                    }
                }
            }
        } onCancel: {
            queue.async { pending.abandon() }
        }
    }

    private func exchange(_ connection: NWConnection, _ bytes: Data, request: HTTPRequest,
                          keep: Bool, reused: Bool, timeout: TimeInterval) async throws -> HTTPResponse {
        if Task.isCancelled {
            connection.cancel()
            throw TransportFailure.cancelled(afterWrite: false)
        }
        let box = ExchangeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                queue.async { [self] in
                    guard !closed, !box.cancelled else {
                        connection.cancel()
                        continuation.resume(throwing: closed ? TransportFailure.closed : TransportFailure.cancelled(afterWrite: false))
                        return
                    }
                    let exchange = HTTPExchange(connection: connection, bytes: bytes, queue: queue,
                                                headRequest: request.method == "HEAD", reused: reused,
                                                maxBody: request.maxResponseBodyBytes,
                                                timeout: timeout) { [self] result in
                        exchanges[ObjectIdentifier(box)] = nil
                        switch result {
                        case .success(let response):
                            if keep, response.reusable { putIdle(connection) } else { connection.cancel() }
                            continuation.resume(returning: response)
                        case .failure(let error):
                            connection.cancel()
                            continuation.resume(throwing: error)
                        }
                    }
                    box.exchange = exchange
                    exchanges[ObjectIdentifier(box)] = exchange
                    exchange.start()
                }
            }
        } onCancel: {
            queue.async {
                box.cancelled = true
                box.exchange?.cancel()
            }
        }
    }
}

enum ExchangeRetry: Error { case staleIdle }

/// Queue-confined handle for a cancellation that may arrive before the
/// exchange exists.
private final class ExchangeBox: @unchecked Sendable {
    var cancelled = false
    var exchange: HTTPExchange?
}

/// One stream open whose caller may go away first.
private final class PendingOpen: @unchecked Sendable {
    private var continuation: CheckedContinuation<OpenedStream, Error>?
    private var abandoned = false
    var opener: StreamOpener?

    /// false when the caller left before the open started.
    func arm(_ c: CheckedContinuation<OpenedStream, Error>) -> Bool {
        if abandoned { c.resume(throwing: TransportFailure.cancelled(afterWrite: false)); return false }
        continuation = c
        return true
    }

    func land(_ result: Result<OpenedStream, GatewayError>) {
        opener = nil
        guard let c = continuation else {
            if case .success(let opened) = result { opened.connection.cancel() }
            return
        }
        continuation = nil
        switch result {
        case .success(let opened): c.resume(returning: opened)
        case .failure(let error): c.resume(throwing: TransportFailure.open(error))
        }
    }

    func abandon() {
        abandoned = true
        let c = continuation
        continuation = nil
        let opener = self.opener
        self.opener = nil
        c?.resume(throwing: TransportFailure.cancelled(afterWrite: false))
        opener?.cancel()
    }
}

/// Writes one request on an open stream and reads its reply, on the
/// transport queue. Finishes exactly once.
final class HTTPExchange: @unchecked Sendable {
    private let connection: NWConnection
    private let bytes: Data
    private let queue: DispatchQueue
    private let reused: Bool
    private var parser: HTTPResponseParser
    private var done: ((Result<HTTPResponse, Error>) -> Void)?
    private var timer: DispatchWorkItem?
    private let timeout: TimeInterval
    /// The request bytes were handed to the stream (send was called).
    private var handedOver = false

    init(connection: NWConnection, bytes: Data, queue: DispatchQueue, headRequest: Bool, reused: Bool,
         maxBody: Int, timeout: TimeInterval, done: @escaping (Result<HTTPResponse, Error>) -> Void) {
        self.connection = connection
        self.bytes = bytes
        self.queue = queue
        self.reused = reused
        self.timeout = timeout
        self.parser = HTTPResponseParser(maxBody: maxBody, headRequest: headRequest)
        self.done = done
    }

    func start() {
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finish(.failure(self.handedOver
                ? TransportFailure.noReply(.message("The host did not reply within %@ seconds.", arguments: [String(Int(self.timeout))]))
                : TransportFailure.notSent(.message("The request could not be sent within %@ seconds.", arguments: [String(Int(self.timeout))]))))
        }
        self.timer = timer
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state { self.fail(.detail(describe(error))) }
            if case .cancelled = state { self.fail(.message("The connection is closed.")) }
        }
        handedOver = true
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, self.done != nil else { return }
            if let error {
                // send() has accepted the bytes. A completion error cannot
                // tell us whether loomd already handled the request.
                self.fail(.detail(describe(error)))
            } else {
                self.receive()
            }
        })
    }

    func cancel() {
        finish(.failure(TransportFailure.cancelled(afterWrite: handedOver)))
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.done != nil else { return }
            do {
                if let data, !data.isEmpty, let response = try self.parser.append(data) {
                    self.finish(.success(response))
                    return
                }
                if isComplete {
                    if self.reused, !self.parser.receivedAny {
                        self.finish(.failure(ExchangeRetry.staleIdle))
                        return
                    }
                    self.finish(.success(try self.parser.finish()))
                    return
                }
            } catch {
                if case HTTPError.tooLarge = error {
                    self.finish(.failure(error))
                } else {
                    self.finish(.failure(TransportFailure.noReply(.message("The host returned an invalid response."))))
                }
                return
            }
            if let error {
                self.fail(.detail(describe(error)))
                return
            }
            self.receive()
        }
    }

    private func fail(_ reason: ArgoClientError.Reason) {
        if reused, !parser.receivedAny {
            finish(.failure(ExchangeRetry.staleIdle))
            return
        }
        finish(.failure(handedOver ? TransportFailure.noReply(reason) : TransportFailure.notSent(reason)))
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard let done else { return }
        self.done = nil
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        done(result)
    }
}
#endif
