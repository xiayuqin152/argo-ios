import XCTest
@testable import ArgoMobileKit

final class NativeHistorySourceTests: XCTestCase {
    private func object(_ body: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    func testRestoredQueueExposesOriginalReferenceWithoutCopyingItems() async throws {
        let transport = FakeTransport { _ in .json(200, NativeHistoryWire.restored) }
        let queue = try await ArgoConnection(host: Fixture.host(), transport: transport).queue(run: "restored-run")
        let source = try XCTUnwrap(queue.nativeSources?.first)
        XCTAssertEqual(queue.nativeSources?.count, 1)
        XCTAssertEqual(source.sourceRun, "source-run")
        XCTAssertEqual(source.target, ArgoAgentIdentity(run: "source-run", engine: "codex", session: "native-thread"))
        XCTAssertEqual(source.nativeHistory, 2)
        XCTAssertEqual(queue.nativeHistory, 2)
        XCTAssertEqual(queue.pending, 0)
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertTrue(queue.later.isEmpty)
        XCTAssertEqual(queue.identity?.run, "restored-run")
        XCTAssertNotEqual(source.target, queue.identity)
        XCTAssertEqual(transport.requests.map(\.request.method), ["GET"])
    }

    func testMixedMetadataKeepsServerTotalAndCurrentItemsSeparate() throws {
        let queue = try JSONDecoder().decode(ArgoQueue.self, from: Data(NativeHistoryWire.mixed.utf8))
        XCTAssertEqual(queue.nativeHistory, 3) // One local handoff plus two original handoffs.
        XCTAssertEqual(queue.nativeSources?.first?.nativeHistory, 2)
        XCTAssertEqual(queue.pending, 2) // Only the current ordinary and scheduled entries.
        XCTAssertEqual(queue.items.map(\.id), ["current-native", "current-pending"])
        XCTAssertEqual(queue.later.map(\.id), ["current-later"])
        XCTAssertTrue((queue.items + queue.later).allSatisfy { $0.target == queue.identity })
        XCTAssertEqual(queue.items.first?.native?.state, .accepted)
        XCTAssertEqual(queue.ws, "ws1")
        XCTAssertEqual(queue.identity, ArgoAgentIdentity(run: "restored-run", engine: "codex", session: "native-thread"))

        var preview = try object(NativeHistoryWire.mixed)
        var items = try XCTUnwrap(preview["items"] as? [[String: Any]])
        items[0]["text"] = "Current preview…"
        items[0]["truncatedFields"] = ["text"]
        preview["items"] = items
        let bounded = try JSONDecoder().decode(ArgoQueue.self, from: data(preview))
        XCTAssertFalse(try XCTUnwrap(bounded.items.first).isComplete("text"))
        XCTAssertEqual(bounded.nativeSources, queue.nativeSources)
        XCTAssertEqual(bounded.nativeHistory, 3)
        XCTAssertEqual(bounded.pending, 2)
        XCTAssertEqual(bounded.identity, queue.identity)
    }

    func testReceiptKeepsSourceMetadataWithoutRebindingTheCurrentSend() async throws {
        let queue = try object(NativeHistoryWire.mixed)
        let item = try XCTUnwrap((queue["items"] as? [[String: Any]])?.first)
        let body = try data(["bounded": true, "byteLimit": ArgoQueue.previewByteLimit,
                             "delivered": false, "item": item, "queue": queue])
        let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: body, reusable: true) }
        let target = ArgoAgentIdentity(run: "restored-run", engine: "codex", session: "native-thread")
        let message = ArgoOutgoingMessage(run: "restored-run", text: "Current run accepted", target: target, attempt: "ios-current-attempt")
        let receipt = try await ArgoConnection(host: Fixture.host(), transport: transport).send(message)
        XCTAssertEqual(receipt.queue.nativeHistory, 3)
        XCTAssertEqual(receipt.queue.nativeSources?.first?.target.run, "source-run")
        XCTAssertEqual(receipt.queued?.target, target)
        XCTAssertEqual(receipt.attempt, message.attempt)
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first?.request)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.target, "/api/agents/restored-run/queue?bounded=1")
        XCTAssertEqual((request.json["target"] as? [String: Any])?["run"] as? String, "restored-run")
    }

    func testMissingSourcesRemainUnknownAndExplicitEmptyIsDistinct() throws {
        var value = try object(NativeHistoryWire.restored)
        value.removeValue(forKey: "nativeSources")
        let legacy = try JSONDecoder().decode(ArgoQueue.self, from: data(value))
        XCTAssertNil(legacy.nativeSources)
        XCTAssertEqual(legacy.nativeHistory, 2)
        value["nativeSources"] = NSNull()
        XCTAssertNil(try JSONDecoder().decode(ArgoQueue.self, from: data(value)).nativeSources)
        value["nativeSources"] = [] as [Any]
        XCTAssertEqual(try JSONDecoder().decode(ArgoQueue.self, from: data(value)).nativeSources, [])
        for malformed in [false, [:] as [String: Any], [NSNull()]] as [Any] {
            value["nativeSources"] = malformed
            XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(value)))
        }
    }

    func testMalformedSourceReferencesRejectTheWholePreview() throws {
        let queue = try object(NativeHistoryWire.restored)
        let source = try XCTUnwrap((queue["nativeSources"] as? [[String: Any]])?.first)
        let target = try XCTUnwrap(source["target"] as? [String: Any])
        func reject(_ source: [String: Any], _ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
            var value = queue
            value["nativeSources"] = [source]
            XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(value)), name, file: file, line: line)
        }
        for run in ["", "unmanaged:t1", "../source", "with space", "with\nnewline", "中文", String(repeating: "r", count: 129)] {
            var malformed = source
            malformed["sourceRun"] = run
            try reject(malformed, "invalid sourceRun: \(run.debugDescription)")
        }
        for field in ["sourceRun", "target", "nativeHistory"] {
            var malformed = source
            malformed.removeValue(forKey: field)
            try reject(malformed, "missing \(field)")
            malformed[field] = NSNull()
            try reject(malformed, "null \(field)")
            malformed[field] = false
            try reject(malformed, "wrong type for \(field)")
        }
        let invalidTargets: [(String, Any)] = [("run", "restored-run"), ("run", NSNull()), ("engine", ""), ("session", "")]
        for (field, invalid) in invalidTargets {
            var wrongTarget = target
            wrongTarget[field] = invalid
            var malformed = source
            malformed["target"] = wrongTarget
            try reject(malformed, "invalid target.\(field)")
        }
        for count in [-1, 1.5, "2"] as [Any] {
            var malformed = source
            malformed["nativeHistory"] = count
            try reject(malformed, "invalid count \(count)")
        }
        var zero = source
        zero["nativeHistory"] = 0
        let valid = try JSONDecoder().decode(ArgoNativeHistorySource.self, from: data(zero))
        XCTAssertEqual(valid.nativeHistory, 0)
        var originalTarget = target
        originalTarget["pid"] = 42
        originalTarget["start"] = "original-process-start"
        originalTarget["started"] = "2026-11-16T07:59:00Z"
        zero["target"] = originalTarget
        let retained = try JSONDecoder().decode(ArgoNativeHistorySource.self, from: data(zero))
        XCTAssertEqual(retained.target, ArgoAgentIdentity(run: "source-run", engine: "codex", pid: 42, start: "original-process-start", started: "2026-11-16T07:59:00Z", session: "native-thread"))
    }

    func testSourceReadsUseOriginalRunAndExistingGETEndpoints() async throws {
        let transport = FakeTransport { request in
            switch request.target {
            case "/api/agents/restored-run/queue?bounded=1": return .json(200, NativeHistoryWire.restored)
            case "/api/agents/source-run/queue?bounded=1": return .json(200, NativeHistoryWire.source)
            case "/api/agents/source-run/queue/source-accepted": return .json(200, NativeHistoryWire.full)
            default: XCTFail("unexpected endpoint \(request.target)"); return .json(404, "{}")
            }
        }
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let current = try await connection.queue(run: "restored-run")
        let reference = try XCTUnwrap(current.nativeSources?.first)
        let original = try await connection.queue(run: reference.sourceRun)
        let handoffs = original.items.filter { $0.native != nil && $0.target == reference.target }
        XCTAssertEqual(handoffs.map(\.native?.state), [.accepted, .unknown])
        XCTAssertEqual(handoffs.count, reference.nativeHistory)
        XCTAssertEqual(original.pending, 1) // A separate original draft stays on the original run.
        XCTAssertNil(original.nativeSources)
        let preview = try XCTUnwrap(handoffs.first)
        let full = try await connection.queueItem(run: reference.sourceRun, itemID: preview.id)
        XCTAssertTrue(preview.matchesFullItem(full.item))
        XCTAssertEqual(full.identity, reference.target)
        XCTAssertEqual(full.item.text, "Original accepted <&>🙂\ntext")
        XCTAssertEqual(transport.requests.map(\.request.method), ["GET", "GET", "GET"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.request.body == nil && $0.request.header("X-Loom-Attempt") == nil })
        XCTAssertEqual(current.items.count, 0)
    }

    func testSourceFullReadsRetainRunIdentityItemAndRevisionGuards() async throws {
        let full = try object(NativeHistoryWire.full)
        var wrongRun = full
        wrongRun["run"] = "restored-run"
        var wrongIdentity = full
        var identity = try XCTUnwrap(full["identity"] as? [String: Any])
        identity["run"] = "restored-run"
        wrongIdentity["identity"] = identity
        var wrongItem = full
        var item = try XCTUnwrap(full["item"] as? [String: Any])
        item["id"] = "another-item"
        wrongItem["item"] = item
        for value in [wrongRun, wrongIdentity, wrongItem] {
            let body = try data(value)
            let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: body, reusable: true) }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).queueItem(run: "source-run", itemID: "source-accepted")
                XCTFail("expected source full binding failure")
            } catch let error as ArgoClientError {
                guard case .invalidResponse = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["GET"])
        }
        let original = try JSONDecoder().decode(ArgoQueueItemDetail.self, from: Data(NativeHistoryWire.full.utf8)).item
        for field in ["updated", "target"] {
            var changed = try XCTUnwrap(full["item"] as? [String: Any])
            changed[field] = field == "updated" ? "2026-11-16T09:00:00Z" as Any : identity as Any
            let revised = try JSONDecoder().decode(ArgoQueuedMessage.self, from: data(changed))
            XCTAssertFalse(original.matchesFullItem(revised), "changed source \(field)")
        }
    }

    func testSourcesDoNotRelaxTheStrictEightMiBPreviewBudget() async throws {
        XCTAssertEqual(HTTPResponseParser.defaultMaxBody, 16_777_216)
        let wire = Data(NativeHistoryWire.mixed.utf8)
        for size in [ArgoQueue.previewByteLimit - 1, ArgoQueue.previewByteLimit, ArgoQueue.previewByteLimit + 1] {
            var body = wire
            body.append(Data(repeating: 0x20, count: size - wire.count))
            let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: body, reusable: true) }
            let connection = ArgoConnection(host: Fixture.host(), transport: transport)
            do {
                let result = try await connection.queue(run: "restored-run")
                XCTAssertLessThan(size, ArgoQueue.previewByteLimit)
                XCTAssertEqual(result.nativeSources?.first?.nativeHistory, 2)
                XCTAssertEqual(result.nativeHistory, 3)
            } catch let error as ArgoClientError {
                XCTAssertGreaterThanOrEqual(size, ArgoQueue.previewByteLimit)
                guard case .invalidResponse = error else { return XCTFail("unexpected error \(error)") }
            }
            XCTAssertEqual(transport.requests.first?.request.maxResponseBodyBytes, 8_388_607)
            XCTAssertEqual(transport.requests.map(\.request.method), ["GET"])
        }
    }
}

// Synthetic responses from the production Go GET/preview/full handlers at dcd3d67.
private enum NativeHistoryWire {
    static let restored = #"""
    {"run":"restored-run","hold":"","pending":0,"nativeHistory":2,"nativeSources":[{"sourceRun":"source-run","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"nativeHistory":2}],"ended":true,"ws":"ws1","identity":{"run":"restored-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"items":[],"later":[],"bounded":true,"byteLimit":8388608}
    """# + "\n"
    static let mixed = #"""
    {"run":"restored-run","hold":"Agent 的终端已关闭","pending":2,"nativeHistory":3,"nativeSources":[{"sourceRun":"source-run","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"nativeHistory":2}],"ended":true,"ws":"ws1","identity":{"run":"restored-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"items":[{"id":"current-native","text":"Current run accepted","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"restored-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}},{"id":"current-pending","text":"Current unsent draft","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"restored-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"}}],"later":[{"id":"current-later","text":"Scheduled current draft","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","not_before":"2026-11-16T10:00:00Z","target":{"run":"restored-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"}}],"bounded":true,"byteLimit":8388608}
    """# + "\n"
    static let source = #"""
    {"run":"source-run","hold":"Agent 的终端已关闭","pending":1,"nativeHistory":2,"ended":true,"ws":"ws1","identity":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"items":[{"id":"source-accepted","text":"Original accepted \u003c\u0026\u003e🙂\ntext","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}},{"id":"source-unknown","text":"Original unknown text","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"native":{"state":"unknown","note":"Synthetic outcome unknown; verify at the original terminal"}},{"id":"source-pending","text":"Unsent source draft","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"}}],"later":[],"bounded":true,"byteLimit":8388608}
    """# + "\n"
    static let full = #"""
    {"run":"source-run","ws":"ws1","identity":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"state":"","ended":true,"later":false,"item":{"id":"source-accepted","text":"Original accepted \u003c\u0026\u003e🙂\ntext","submit":true,"source":"ios","created":"2026-11-16T08:00:00Z","target":{"run":"source-run","engine":"codex","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"native-thread"},"native":{"state":"accepted","note":"Codex 已接收；原生会话记录将在 Codex 开始处理后显示"}}}
    """# + "\n"
}
