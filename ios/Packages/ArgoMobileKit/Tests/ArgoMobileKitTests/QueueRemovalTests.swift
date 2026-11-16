import XCTest
@testable import ArgoMobileKit

final class QueueRemovalTests: XCTestCase {
    private func object() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(QueueRemovalWire.removed.utf8)) as? [String: Any])
    }

    private func response(_ value: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [], body: try JSONSerialization.data(withJSONObject: value), reusable: true)
    }

    func testRemovalUsesOriginalRunAndEscapedItemIDWithNoBodyOrPost() async throws {
        let transport = FakeTransport { _ in .json(200, QueueRemovalWire.removed) }
        let queue = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "unknown/a b")
        XCTAssertEqual(queue.run, "source-run")
        XCTAssertEqual(queue.identity, ArgoAgentIdentity(run: "source-run", engine: "claude", session: "source-run-thread"))
        XCTAssertEqual(queue.items.map(\.id), ["kept", "native-only"])
        XCTAssertEqual(queue.items.last?.native?.state, .accepted)
        XCTAssertEqual(queue.pending, 1)
        XCTAssertEqual(queue.nativeHistory, 1)
        XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.request.target, "/api/agents/source-run/queue/unknown%2Fa%20b?bounded=1")
        XCTAssertNil(sent.request.body)
        XCTAssertNil(sent.request.header("Content-Type"))
        XCTAssertNil(sent.request.header("X-Loom-Attempt"))
        XCTAssertEqual(sent.request.maxResponseBodyBytes, 8_388_607)
        XCTAssertFalse(sent.reuse)
        let encoded = String(decoding: try sent.request.encoded(keepAlive: sent.reuse), as: UTF8.self)
        XCTAssertTrue(encoded.contains("Content-Length: 0\r\n"))
    }

    func testInvalidRunAndEmptyItemIDAreRefusedBeforeTransport() async throws {
        let transport = FakeTransport { _ in XCTFail("invalid removal reached transport"); return .json(200, QueueRemovalWire.removed) }
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        for (run, id) in [("", "item"), ("unmanaged:t1", "item"), ("source/run", "item"), ("with space", "item"), (String(repeating: "r", count: 129), "item"), ("source-run", "")] {
            do {
                _ = try await connection.removeQueueItem(run: run, itemID: id)
                XCTFail("expected local refusal")
            } catch let error as ArgoClientError {
                guard case .refusedLocally = error else { return XCTFail("unexpected error \(error)") }
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(transport.tokenCalls, 0)
    }

    func testServerErrorsPropagateWithoutAuthRetryOrNativeHideFallback() async throws {
        for (status, body) in [(409, QueueRemovalWire.nativeConflict), (404, QueueRemovalWire.missing),
                               (401, #"{"error":"synthetic auth refusal","code":"auth_refused"}"#),
                               (500, #"{"error":"synthetic save failure","code":"save_failed"}"#)] {
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            let transport = FakeTransport { _ in .json(status, body) }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "original-item")
                XCTFail("expected HTTP error")
            } catch let error as ArgoClientError {
                guard case .http(let code, let message, let serverCode) = error else { return XCTFail("unexpected error \(error)") }
                XCTAssertEqual(code, status)
                XCTAssertEqual(message, fields["error"] as? String)
                XCTAssertEqual(serverCode, fields["code"] as? String)
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
            XCTAssertEqual(transport.requests.first?.request.target, "/api/agents/source-run/queue/original-item?bounded=1")
            XCTAssertEqual(transport.tokenCalls, 1)
        }
    }

    func testTransportFailuresKeepExistingWriteClassificationWithoutReplay() async throws {
        for (failure, uncertain) in [(TransportFailure.noReply("synthetic lost reply"), true), (.notSent("synthetic write failure"), false)] {
            let transport = FakeTransport { _ in throw failure }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "unknown/a b")
                XCTFail("expected transport failure")
            } catch let error as ArgoClientError {
                if uncertain {
                    guard case .deliveryUnknown = error else { return XCTFail("unexpected error \(error)") }
                } else {
                    guard case .notSent = error else { return XCTFail("unexpected error \(error)") }
                }
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
        }
        let tokenFailure = FakeTransport()
        tokenFailure.tokenError = TransportFailure.noReply("synthetic token stream failure")
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: tokenFailure).removeQueueItem(run: "source-run", itemID: "item")
            XCTFail("expected failure before DELETE")
        } catch let error as ArgoClientError {
            guard case .notSent = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertTrue(tokenFailure.requests.isEmpty)
    }

    func testRemovalRequiresBoundedDecodableQueueResponse() async throws {
        let valid = try object()
        var unbounded = valid; unbounded["bounded"] = false
        var wrongLimit = valid; wrongLimit["byteLimit"] = ArgoQueue.previewByteLimit + 1
        var malformed = valid; malformed["items"] = "invalid queue items"
        let bodies = [HTTPResponse.json(200, "{}"), .json(204, ""), .json(200, "not JSON"),
                      try response(unbounded), try response(wrongLimit), try response(malformed)]
        for body in bodies {
            let transport = FakeTransport { _ in body }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "item")
                XCTFail("expected unknown removal response")
            } catch let error as ArgoClientError {
                guard case .deliveryUnknown = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
        }
    }

    func testRemovalResponseMustKeepOriginalRunAndQueueIdentity() async throws {
        let valid = try object()
        var wrongRun = valid; wrongRun["run"] = "current-run"
        var wrongIdentity = valid
        wrongIdentity["identity"] = ["run": "current-run", "engine": "claude", "session": "source-run-thread"]
        var missingIdentity = valid; missingIdentity.removeValue(forKey: "identity")
        let wrapped: [String: Any] = ["bounded": true, "byteLimit": ArgoQueue.previewByteLimit, "queue": valid]
        for body in [wrongRun, wrongIdentity, missingIdentity, wrapped] {
            let reply = try response(body)
            let transport = FakeTransport { _ in reply }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "item")
                XCTFail("expected mismatched source queue")
            } catch let error as ArgoClientError {
                guard case .invalidResponse = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
        }
    }

    func testRemovalKeepsTheStrictEightMiBPreviewLimit() async throws {
        let original = Data(QueueRemovalWire.removed.utf8)
        for size in [ArgoQueue.previewByteLimit - 1, ArgoQueue.previewByteLimit, ArgoQueue.previewByteLimit + 1] {
            var body = original
            body.append(Data(repeating: 0x20, count: size - original.count))
            let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: body, reusable: true) }
            do {
                let queue = try await ArgoConnection(host: Fixture.host(), transport: transport).removeQueueItem(run: "source-run", itemID: "unknown/a b")
                XCTAssertLessThan(size, ArgoQueue.previewByteLimit)
                XCTAssertEqual(queue.items.map(\.id), ["kept", "native-only"])
            } catch let error as ArgoClientError {
                XCTAssertGreaterThanOrEqual(size, ArgoQueue.previewByteLimit)
                guard case .deliveryUnknown = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(transport.requests.first?.request.maxResponseBodyBytes, 8_388_607)
            XCTAssertEqual(transport.requests.map(\.request.method), ["DELETE"])
        }
    }
}

// Synthetic responses from the existing production DELETE route at dcd3d67.
private enum QueueRemovalWire {
    static let removed = #"""
    {"run":"source-run","hold":"Agent 的终端已关闭","pending":1,"nativeHistory":1,"ended":true,"ws":"ws1","identity":{"run":"source-run","engine":"claude","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"source-run-thread"},"items":[{"id":"kept","text":"Unrelated original draft","submit":true,"source":"ios","created":"2026-11-16T09:25:00Z","target":{"run":"source-run","engine":"claude","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"source-run-thread"}},{"id":"native-only","text":"Native record","submit":true,"source":"ios","created":"2026-11-16T09:25:00Z","target":{"run":"source-run","engine":"claude","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"source-run-thread"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}}],"later":[],"bounded":true,"byteLimit":8388608}
    """# + "\n"
    static let nativeConflict = #"""
    {"bounded":true,"byteLimit":8388608,"error":"这是只读原生交接记录，不能编辑、再次发送或撤回；移除 Argo 记录不会撤回 Codex 消息"}
    """# + "\n"
    static let missing = #"""
    {"bounded":true,"byteLimit":8388608,"error":"这条排队消息不存在"}
    """# + "\n"
}
