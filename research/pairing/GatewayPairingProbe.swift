import ArgoMobileKit
import Foundation

// Only the network boundary is replaced. The runner appends GatewayPairing
// verbatim from GatewayConnection.swift, including any private helper below it.
struct GatewayEndpoint: Sendable {
    let host: String
    let port: Int
    let fingerprint: Data
    init(host: String, port: Int, fingerprint: Data) {
        self.host = host; self.port = port; self.fingerprint = fingerprint
    }
    init(_ code: PairingCode) {
        self.init(host: code.host, port: code.port, fingerprint: code.fingerprint)
    }
}

final class ProbeConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func cancel() { lock.lock(); closed = true; lock.unlock() }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

struct OpenedStream {
    let connection: ProbeConnection
    let reply: GatewayReply
    let rest = Data()
}

final class ProbeStore: @unchecked Sendable {
    static let shared = ProbeStore()
    private let lock = NSLock()
    private var attempts: [StreamOpener] = []
    func add(_ attempt: StreamOpener) { lock.lock(); attempts.append(attempt); lock.unlock() }
    var all: [StreamOpener] { lock.lock(); defer { lock.unlock() }; return attempts }
}

final class StreamOpener: @unchecked Sendable {
    let endpoint: GatewayEndpoint
    let header: GatewayHeader
    let connection = ProbeConnection()
    private let queue: DispatchQueue
    private let completion: (Result<OpenedStream, GatewayError>) -> Void
    private var finished = false

    init(_ endpoint: GatewayEndpoint, _ header: GatewayHeader, _ queue: DispatchQueue,
         _ completion: @escaping (Result<OpenedStream, GatewayError>) -> Void) {
        self.endpoint = endpoint; self.header = header; self.queue = queue; self.completion = completion
    }

    @discardableResult
    static func open(_ endpoint: GatewayEndpoint, header: GatewayHeader, queue: DispatchQueue,
                     timeout: TimeInterval, completion: @escaping (Result<OpenedStream, GatewayError>) -> Void) -> StreamOpener? {
        let attempt = StreamOpener(endpoint, header, queue, completion)
        ProbeStore.shared.add(attempt)
        return attempt
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        connection.cancel()
        completion(.failure(.network("probe cancelled")))
    }

    func reply(_ result: Result<GatewayReply, GatewayError>) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            completion(result.map { OpenedStream(connection: connection, reply: $0) })
        }
    }
}

actor PairResult {
    enum Outcome: Equatable { case credential, cancelled, failure(GatewayError), otherFailure }
    var outcome: Outcome?
    func run(_ code: PairingCode) async {
        do { _ = try await GatewayPairing.pair(code, name: "probe"); outcome = .credential }
        catch is CancellationError { outcome = .cancelled }
        catch let error as GatewayError { outcome = .failure(error) }
        catch { outcome = .otherFailure }
    }
}

@main @MainActor struct PairingProbe {
    static func eventually(_ check: () async -> Bool) async -> Bool {
        for _ in 0..<50 {
            if await check() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await check()
    }

    static func main() async throws {
        var failures = 0
        func expect(_ ok: Bool, _ label: String) {
            print("\(ok ? "PASS" : "FAIL"): \(label)")
            if !ok { failures += 1 }
        }
        let fingerprint = Base64URL.encode(Data(repeating: 1, count: 32))
        let secret = Base64URL.encode(Data(repeating: 2, count: 16))
        let text = "argo1:127.0.0.1:25920:\(fingerprint):\(secret)"
        let code = try PairingCode(parsing: text)
        expect(try PairingCode(parsing: " $ argo pair\n'\(text)'\n ") == code,
               "QR and pasted terminal text parse to the same direct gateway")
        expect(try PairingCode(parsing: text.replacingOccurrences(of: "argo1:", with: "loom1:")) == code,
               "a legacy direct gateway code still parses")
        expect(GatewayHandshake.isClosed(tlsStatus: -9805) && GatewayHandshake.isClosed(tlsStatus: -9806)
               && GatewayHandshake.isClosed(posix: POSIXErrorCode.ECONNRESET.rawValue),
               "TLS close and connection reset retain their handshake classification")
        expect(!GatewayHandshake.isClosed(tlsStatus: -9813)
               && !GatewayHandshake.isClosed(posix: POSIXErrorCode.ECONNREFUSED.rawValue),
               "certificate errors and connection refusal are classified separately")
        let reply = try JSONDecoder().decode(GatewayReply.self, from: Data(
            "{\"ok\":true,\"device\":\"probe-device\",\"token\":\"\(String(repeating: "a", count: 43))\"}".utf8))

        let cancelled = PairResult()
        let task = Task { await cancelled.run(code) }
        let began = await eventually { ProbeStore.shared.all.count == 1 }
        expect(began, "pairing starts one handshake")
        let held = ProbeStore.shared.all[0]
        task.cancel()
        let ended = await eventually { await cancelled.outcome != nil }
        expect(ended, "cancel finishes while the peer is still silent")
        expect(held.connection.isClosed, "cancel closes the pending handshake")
        // Also releases the unfixed baseline so a failed reproduction exits.
        held.reply(.success(reply))
        await task.value
        let cancelledOutcome = await cancelled.outcome
        expect(cancelledOutcome == .cancelled, "a late credential cannot complete a cancelled pairing")

        let countBefore = ProbeStore.shared.all.count
        let preCancelled = PairResult()
        let beforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await preCancelled.run(code)
        }
        let preEnded = await eventually { await preCancelled.outcome != nil }
        expect(preEnded, "already cancelled pairing finishes without contacting the peer")
        let countAfter = ProbeStore.shared.all.count
        expect(countAfter == countBefore, "already cancelled pairing never opens a stream")
        if countAfter > countBefore { ProbeStore.shared.all.last?.reply(.success(reply)) }
        await beforeStart.value
        let preOutcome = await preCancelled.outcome
        expect(preOutcome == .cancelled, "already cancelled pairing reports CancellationError")

        let success = PairResult()
        let successCount = ProbeStore.shared.all.count
        let successful = Task { await success.run(code) }
        let successOpened = await eventually { ProbeStore.shared.all.count > successCount }
        expect(successOpened, "an active pairing can open after a cancellation")
        let active = ProbeStore.shared.all.last!
        expect(active.endpoint.fingerprint == code.fingerprint && active.header.secret == code.secret,
               "the certificate pin and one-time secret reach the stream unchanged")
        active.reply(.success(reply))
        await successful.value
        let successOutcome = await success.outcome
        expect(successOutcome == .credential && active.connection.isClosed,
               "success returns a credential and closes the pairing stream")

        let rejected = PairResult()
        let rejectionCount = ProbeStore.shared.all.count
        let rejection = Task { await rejected.run(code) }
        let rejectOpened = await eventually { ProbeStore.shared.all.count > rejectionCount }
        expect(rejectOpened, "a rejected pairing opens normally")
        ProbeStore.shared.all.last!.reply(.failure(.pairingRejected("expired")))
        await rejection.value
        let rejectionOutcome = await rejected.outcome
        expect(rejectionOutcome == .failure(.pairingRejected("expired")),
               "expired or used code rejection is preserved")

        print("Pairing probe: \(failures) failures")
        if failures > 0 { exit(1) }
    }
}
