import XCTest
@testable import ArgoMobileKit

/// A token source that observes cancellation but can still deliver a late reply.
/// No gateway, real credential or HTTP socket is involved.
private actor HeldTokenTransport: ArgoHTTPTransport {
    private(set) var calls = 0
    private(set) var cancelled: Set<Int> = []
    private(set) var requests: [HTTPRequest] = []
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]

    func loomdToken() async throws -> String {
        calls += 1
        let id = calls
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: {
            Task { await self.recordCancellation(id) }
        }
    }

    private func recordCancellation(_ id: Int) { cancelled.insert(id) }

    func resolve(_ id: Int, token: String) { pending.removeValue(forKey: id)?.resume(returning: token) }

    func releaseAll() {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: TransportFailure.closed) }
    }

    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        requests.append(request)
        return .json(200, request.target == "/api/health" ? Fixture.health : "[]")
    }

    // Intentionally does not release pending replies: ArgoConnection must end
    // its own waiters even when a transport ignores cancellation/close.
    func close() async { }
}

private actor TokenRead {
    enum Outcome: Equatable { case success, cancelled, closed, failed }
    private(set) var started = false
    private(set) var outcome: Outcome?

    func run(_ connection: ArgoConnection, connect: Bool = false) async {
        started = true
        do {
            if connect { _ = try await connection.connect() }
            else { _ = try await connection.workspaces() }
            outcome = .success
        } catch is CancellationError { outcome = .cancelled }
        catch ArgoClientError.closed { outcome = .closed }
        catch { outcome = .failed }
    }
}

final class TokenCancellationTests: XCTestCase {
    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func testCancelledTokenWaiterFinishesBeforeTokenReply() async {
        let transport = HeldTokenTransport()
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let read = TokenRead()
        let task = Task { await read.run(connection) }
        let opened = await eventually { await transport.calls == 1 }
        XCTAssertTrue(opened)
        task.cancel()
        let ended = await eventually { await read.outcome != nil }
        XCTAssertTrue(ended, "token cancellation must finish before the token reply")
        let cancelled = await eventually { await transport.cancelled == [1] }
        XCTAssertTrue(cancelled, "the last waiter must cancel the underlying token fetch")
        await transport.resolve(1, token: "late-token")
        await task.value
        let outcome = await read.outcome
        let requests = await transport.requests
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(requests.isEmpty)
        await connection.close()
    }

    func testCancellingOneWaiterPreservesSharedFetchAndCache() async {
        let transport = HeldTokenTransport()
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let first = TokenRead(), second = TokenRead()
        let a = Task { await first.run(connection) }
        let opened = await eventually { await transport.calls == 1 }
        XCTAssertTrue(opened)
        let b = Task { await second.run(connection) }
        let started = await eventually { await second.started }
        XCTAssertTrue(started)
        _ = await connection.isClosed
        a.cancel()
        let ended = await eventually { await first.outcome != nil }
        XCTAssertTrue(ended)
        let cancelled = await transport.cancelled
        XCTAssertTrue(cancelled.isEmpty, "another caller still needs this token fetch")
        await transport.resolve(1, token: "shared-token")
        await a.value
        await b.value
        let secondOutcome = await second.outcome
        XCTAssertEqual(secondOutcome, .success)
        do { _ = try await connection.workspaces() }
        catch { XCTFail("cached token read failed: \(error)") }
        let calls = await transport.calls
        let requests = await transport.requests
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.header("Authorization") == "Bearer shared-token" })
        await connection.close()
    }

    func testLateCancelledFetchCannotCompleteOrOverwriteReplacement() async {
        let transport = HeldTokenTransport()
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let first = TokenRead()
        let a = Task { await first.run(connection) }
        let opened = await eventually { await transport.calls == 1 }
        XCTAssertTrue(opened)
        a.cancel()
        let ended = await eventually { await first.outcome == .cancelled }
        XCTAssertTrue(ended)
        let second = TokenRead()
        let b = Task { await second.run(connection) }
        let replaced = await eventually { await transport.calls == 2 }
        XCTAssertTrue(replaced)
        await transport.resolve(1, token: "obsolete-token")
        await a.value
        // A subsequent actor call observes any effects of the late completion.
        _ = await connection.isClosed
        let pendingOutcome = await second.outcome
        XCTAssertNil(pendingOutcome)
        await transport.resolve(2, token: "replacement-token")
        await b.value
        do { _ = try await connection.workspaces() }
        catch { XCTFail("replacement token read failed: \(error)") }
        let requests = await transport.requests
        let calls = await transport.calls
        let outcome = await second.outcome
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.header("Authorization") == "Bearer replacement-token" })
        await connection.close()
    }

    func testCloseEndsTokenWaitWithoutTransportCooperation() async {
        let transport = HeldTokenTransport()
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let read = TokenRead()
        let task = Task { await read.run(connection) }
        let opened = await eventually { await transport.calls == 1 }
        XCTAssertTrue(opened)
        await connection.close()
        let ended = await eventually { await read.outcome == .closed }
        XCTAssertTrue(ended)
        await transport.releaseAll()
        await task.value
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testConnectJoinsAnExistingTokenFetch() async {
        let transport = HeldTokenTransport()
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let first = TokenRead(), second = TokenRead()
        let a = Task { await first.run(connection) }
        let opened = await eventually { await transport.calls == 1 }
        XCTAssertTrue(opened)
        let b = Task { await second.run(connection, connect: true) }
        let started = await eventually { await second.started }
        XCTAssertTrue(started)
        _ = await connection.isClosed
        await transport.resolve(1, token: "shared-token")
        await a.value
        // Release an unexpected second fetch as well, so a regression fails
        // with an assertion instead of stranding the test process.
        let calls = await transport.calls
        if calls > 1 { await transport.resolve(2, token: "unexpected-token") }
        await b.value
        let outcome = await second.outcome
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome, .success)
        await connection.close()
    }
}
