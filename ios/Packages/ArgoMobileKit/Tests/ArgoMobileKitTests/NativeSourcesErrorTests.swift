import XCTest
@testable import ArgoMobileKit

/// Synthetic codec fixtures for the optional field contract. These are not
/// captured backend responses; production-wire verification is independent.
final class NativeSourcesErrorTests: XCTestCase {
    private let warning = "Earlier handoff sources are incomplete.\n来源暂不可读🙂"
    private let target: [String: Any] = ["run": "current-run", "engine": "codex", "session": "native-thread"]

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func queue() -> [String: Any] {
        ["run": "current-run", "ws": "ws1", "identity": target, "state": "working",
         "hold": "Current queue hold", "notice": "Current queue notice",
         "items": [["id": "current-pending", "text": "Current draft", "target": target]],
         "later": [["id": "current-later", "text": "Scheduled draft", "target": target, "not_before": "2026-11-16T12:00:00Z"]],
         "pending": 2, "nativeHistory": 2,
         "nativeSources": [["sourceRun": "readable-source", "target": ["run": "readable-source", "engine": "codex", "session": "native-thread"], "nativeHistory": 2]]]
    }

    private func card() -> [String: Any] {
        ["run": "current-run", "ws": "ws1", "state": "working", "stateText": "Current agent state",
         "error": "Current agent error", "queued": 2, "nativeHistory": 2]
    }

    func testQueueRetainsPartialSourcesAndCurrentQueueForOptionalWarning() throws {
        for value in [nil, NSNull(), "", warning] as [Any?] {
            var body = queue()
            body["nativeSourcesError"] = value
            let decoded = try JSONDecoder().decode(ArgoQueue.self, from: data(body))
            XCTAssertEqual(decoded.nativeSourcesError, value as? String)
            XCTAssertEqual(decoded.run, "current-run")
            XCTAssertEqual(decoded.identity, ArgoAgentIdentity(run: "current-run", engine: "codex", session: "native-thread"))
            XCTAssertEqual(decoded.items.map(\.id), ["current-pending"])
            XCTAssertEqual(decoded.later.map(\.id), ["current-later"])
            XCTAssertEqual(decoded.pending, 2)
            XCTAssertEqual(decoded.nativeHistory, 2)
            XCTAssertEqual(decoded.nativeSources?.first?.sourceRun, "readable-source")
            XCTAssertEqual(decoded.nativeSources?.first?.nativeHistory, 2)
            XCTAssertEqual(decoded.hold, "Current queue hold")
        }
        var unavailable = queue()
        unavailable.removeValue(forKey: "nativeSources")
        unavailable["nativeSourcesError"] = warning
        let decoded = try JSONDecoder().decode(ArgoQueue.self, from: data(unavailable))
        XCTAssertNil(decoded.nativeSources)
        XCTAssertEqual(decoded.nativeSourcesError, warning)
        XCTAssertEqual(decoded.nativeHistory, 2)
        XCTAssertEqual(decoded.pending, 2)
    }

    func testCardWarningStaysSeparateFromCurrentAgentErrorAndCounts() throws {
        for value in [nil, NSNull(), "", warning] as [Any?] {
            var body = card()
            body["nativeSourcesError"] = value
            let decoded = try JSONDecoder().decode(ArgoAgentCard.self, from: data(body))
            XCTAssertEqual(decoded.nativeSourcesError, value as? String)
            XCTAssertEqual(decoded.run, "current-run")
            XCTAssertEqual(decoded.state, "working")
            XCTAssertEqual(decoded.stateText, "Current agent state")
            XCTAssertEqual(decoded.error, "Current agent error")
            XCTAssertEqual(decoded.queued, 2)
            XCTAssertEqual(decoded.nativeHistory, 2)
        }
        let terminal = try JSONDecoder().decode(ArgoTerminalView.self, from: data([
            "id": "manual-terminal", "ws": "ws1", "unmanaged": ["engine": "codex", "state": "working"]]))
        let manual = try XCTUnwrap(ArgoAgentCard(manual: terminal))
        XCTAssertNil(manual.nativeSourcesError)
        XCTAssertEqual(manual.run, "unmanaged:manual-terminal")
    }

    func testInvalidWarningTypesUseNormalDecoderFailures() throws {
        for invalid in [false, 42, 1.5, [] as [Any], [:] as [String: Any]] as [Any] {
            var queueBody = queue()
            queueBody["nativeSourcesError"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(queueBody))) { error in
                guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("unexpected error \(error)") }
                XCTAssertEqual(context.codingPath.last?.stringValue, "nativeSourcesError")
            }
            var cardBody = card()
            cardBody["nativeSourcesError"] = invalid
            XCTAssertThrowsError(try JSONDecoder().decode(ArgoAgentCard.self, from: data(cardBody))) { error in
                guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("unexpected error \(error)") }
                XCTAssertEqual(context.codingPath.last?.stringValue, "nativeSourcesError")
            }
        }
    }

    func testPartialSourceFailurePreservesSuccessfulCurrentReceiptsWithoutReplay() async throws {
        for outcome in ["delivered", "accepted", "unknown"] {
            var queueBody = queue()
            queueBody["nativeSourcesError"] = warning
            let nativeItem: [String: Any] = ["id": "current-native", "text": "Current input", "target": target,
                                             "native": ["state": outcome, "note": "Current handoff note"]]
            if outcome != "delivered" {
                queueBody["items"] = [nativeItem] + (try XCTUnwrap(queueBody["items"] as? [[String: Any]]))
                queueBody["nativeHistory"] = 3
            }
            var receiptBody: [String: Any] = ["bounded": true, "byteLimit": ArgoQueue.previewByteLimit,
                                              "delivered": outcome == "delivered", "queue": queueBody, "note": "Current receipt note"]
            if outcome != "delivered" {
                receiptBody["item"] = nativeItem
            }
            let encoded = try data(receiptBody)
            let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: encoded, reusable: true) }
            let identity = ArgoAgentIdentity(run: "current-run", engine: "codex", session: "native-thread")
            let message = ArgoOutgoingMessage(run: "current-run", text: "Current input", target: identity, attempt: "ios-original-attempt")
            let receipt = try await ArgoConnection(host: Fixture.host(), transport: transport).send(message)
            XCTAssertEqual(receipt.delivered, outcome == "delivered")
            XCTAssertEqual(receipt.queue.nativeSourcesError, warning)
            XCTAssertEqual(receipt.queue.nativeSources?.first?.sourceRun, "readable-source")
            XCTAssertEqual(receipt.queue.items.map(\.id), outcome == "delivered" ? ["current-pending"] : ["current-native", "current-pending"])
            XCTAssertEqual(receipt.queue.later.map(\.id), ["current-later"])
            XCTAssertEqual(receipt.queue.pending, 2)
            XCTAssertEqual(receipt.queue.nativeHistory, outcome == "delivered" ? 2 : 3)
            XCTAssertEqual(receipt.queue.hold, "Current queue hold")
            XCTAssertEqual(receipt.note, "Current receipt note")
            XCTAssertEqual(receipt.attempt, message.attempt)
            if outcome == "delivered" {
                XCTAssertNil(receipt.queued)
            } else {
                XCTAssertEqual(receipt.queued?.target, identity)
                XCTAssertEqual(receipt.queued?.native?.state, outcome == "accepted" ? .accepted : .unknown)
                XCTAssertEqual(receipt.queued?.native?.note, "Current handoff note")
            }
            XCTAssertEqual(transport.requests.map(\.request.method), ["POST"])
            XCTAssertEqual(transport.requests.first?.request.header("X-Loom-Attempt"), message.attempt)
        }
    }

    func testPartialWarningDoesNotSuppressCurrentIdentityOrSourceValidation() throws {
        var invalidIdentity = queue()
        invalidIdentity["nativeSourcesError"] = warning
        invalidIdentity["identity"] = ["run": "current-run", "engine": false, "session": "native-thread"]
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(invalidIdentity))) { error in
            guard case DecodingError.typeMismatch(_, let context) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(context.codingPath.map(\.stringValue), ["identity", "engine"])
        }
        var invalidSource = queue()
        invalidSource["nativeSourcesError"] = warning
        invalidSource["nativeSources"] = [["sourceRun": "readable-source", "target": target, "nativeHistory": 2]]
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(invalidSource)))
        var invalidItems = queue()
        invalidItems["nativeSourcesError"] = warning
        invalidItems["items"] = "malformed current queue"
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: data(invalidItems)))
    }

    func testMalformedWarningUsesExistingConnectionReadAndReceiptErrors() async throws {
        var queueBody = queue()
        queueBody["nativeSourcesError"] = true
        let readBody = try data(queueBody.merging(["bounded": true, "byteLimit": ArgoQueue.previewByteLimit]) { _, new in new })
        let read = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: readBody, reusable: true) }
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: read).queue(run: "current-run")
            XCTFail("expected invalid read response")
        } catch let error as ArgoClientError {
            guard case .invalidResponse = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(read.requests.map(\.request.method), ["GET"])
        let writeBody = try data(["bounded": true, "byteLimit": ArgoQueue.previewByteLimit, "delivered": true, "queue": queueBody])
        let write = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: writeBody, reusable: true) }
        let message = ArgoOutgoingMessage(run: "current-run", text: "Current input", target: nil, attempt: "ios-original-attempt")
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: write).send(message)
            XCTFail("expected unknown receipt representation")
        } catch let error as ArgoClientError {
            guard case .deliveryUnknown = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(write.requests.map(\.request.method), ["POST"])
        XCTAssertEqual(write.requests.first?.request.header("X-Loom-Attempt"), message.attempt)
    }
}
