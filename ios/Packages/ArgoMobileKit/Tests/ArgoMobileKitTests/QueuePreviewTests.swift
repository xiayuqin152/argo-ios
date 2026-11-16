import XCTest
@testable import ArgoMobileKit

final class QueuePreviewTests: XCTestCase {
    private let identity: [String: Any] = ["run": "r1", "engine": "codex", "session": "original", "pid": 0, "start": "", "started": "0001-01-01T00:00:00Z"]

    private func goJSON(_ object: Any) throws -> Data {
        var text = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        for (value, escaped) in [("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), ("\u{2028}", "\\u2028"), ("\u{2029}", "\\u2029")] {
            text = text.replacingOccurrences(of: value, with: escaped)
        }
        return Data((text + "\n").utf8)
    }

    private func item(_ text: String, id: String = "q1") -> [String: Any] {
        ["id": id, "text": text, "target": identity, "submit": true, "source": "ios", "created": "2026-11-16T04:53:00Z"]
    }
    private func detail(_ item: [String: Any]) -> [String: Any] {
        ["run": "r1", "ws": "w1", "identity": identity, "state": "working", "ended": false, "later": false, "item": item]
    }

    func testMaximumPreviewBodiesFitTheUnchangedParserWithGoEscaping() async throws {
        XCTAssertEqual(HTTPResponseParser.defaultMaxBody, 16_777_216)
        for unit in ["English message ", "中文🙂", "\"\\\n\t", "<b>&中文</b>\u{2028}"] {
            func response(_ repeats: Int, hold: String = "…") throws -> Data {
                let text = String(repeating: unit, count: repeats) + "…"
                let items = (0..<32).map { n -> [String: Any] in
                    var value = item(text, id: "q\(n)")
                    value["truncatedFields"] = ["text"]
                    return value
                }
                let queue: [String: Any] = ["run": "r1", "ws": "w1", "identity": identity, "state": "working", "hold": hold,
                    "truncatedFields": ["hold"], "items": items, "later": [], "pending": 32, "nativeHistory": 0]
                return try goJSON(["bounded": true, "byteLimit": 8_388_608, "delivered": false, "item": items[0], "queue": queue])
            }
            let base = try response(0).count
            let increment = try response(1).count - base
            let low = min((256 * 1024 - 4) / unit.utf8.count, (ArgoQueue.previewByteLimit - 1 - base) / increment)
            let padding = ArgoQueue.previewByteLimit - 1 - (try response(low).count)
            let body = try response(low, hold: String(repeating: "h", count: padding) + "…")
            XCTAssertEqual(body.count, 8_388_607)
            var parser = HTTPResponseParser()
            _ = try parser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
            var parsed: HTTPResponse?
            for start in stride(from: 0, to: body.count, by: 16 * 1024) {
                parsed = try parser.append(body.subdata(in: start..<min(body.count, start + 16 * 1024))) ?? parsed
            }
            let received = try XCTUnwrap(parsed)
            let transport = FakeTransport { _ in received }
            let connection = ArgoConnection(host: Fixture.host(), transport: transport)
            let result = try await connection.send(ArgoOutgoingMessage(run: "r1", text: "original", target: nil))
            XCTAssertEqual(result.queue.items.count, 32)
            XCTAssertEqual(result.queue.items.map(\.id), (0..<32).map { "q\($0)" })
            XCTAssertEqual(result.queued?.text, String(repeating: unit, count: low) + "…")
            XCTAssertFalse(try XCTUnwrap(result.queued).isComplete("text"))
            XCTAssertEqual(result.queue.truncatedFields, ["hold"])
            XCTAssertEqual(transport.requests.first?.request.maxResponseBodyBytes, 8_388_607)
        }
    }

    func testFullReadPreservesExactTextAndUsesOnlyEscapedGET() async throws {
        let text = "  原文🙂\n\"\\<html>&\u{2028}" + String(repeating: "文", count: 80_000)
        let body = try goJSON(detail(item(text, id: "q/a b")))
        let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: body, reusable: true) }
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let full = try await connection.queueItem(run: "r1", itemID: "q/a b")
        XCTAssertEqual(full.item.text, text)
        XCTAssertEqual(full.ws, "w1")
        XCTAssertEqual(full.identity.session, "original")
        let request = try XCTUnwrap(transport.requests.first?.request)
        XCTAssertEqual(request.target, "/api/agents/r1/queue/q%2Fa%20b")
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.body)
        XCTAssertNil(request.header("X-Loom-Attempt"))
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testFutureAndMalformedTruncationNeverBecomeCompleteText() throws {
        for markers in [["text"], ["future.field"]] {
            var value = item("preview…")
            value["truncatedFields"] = markers
            value["native"] = ["state": "future-state", "note": "unknown"]
            let preview = try JSONDecoder().decode(ArgoQueuedMessage.self, from: goJSON(value))
            XCTAssertFalse(preview.isComplete("text"))
            XCTAssertEqual(preview.native?.state, .unknown)
            XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueueItemDetail.self, from: goJSON(detail(value))))
        }
        var sourceOnly = item("complete text")
        sourceOnly["truncatedFields"] = ["source"]
        XCTAssertTrue(try JSONDecoder().decode(ArgoQueuedMessage.self, from: goJSON(sourceOnly)).isComplete("text"))
        sourceOnly["truncatedFields"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueuedMessage.self, from: goJSON(sourceOnly)))
        sourceOnly["truncatedFields"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueuedMessage.self, from: goJSON(sourceOnly)))
        var markedQueue: [String: Any] = ["run": "r1", "truncatedFields": NSNull()]
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueue.self, from: goJSON(markedQueue)))
        markedQueue = detail(item("complete"))
        markedQueue["truncatedFields"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueueItemDetail.self, from: goJSON(markedQueue)))
        var missing = item("")
        missing["text"] = nil
        XCTAssertThrowsError(try JSONDecoder().decode(ArgoQueueItemDetail.self, from: goJSON(detail(missing))))
    }

    func testFullReadRejectsWrongIdentityAndMissingRecordsWithoutWriting() async throws {
        for code in [404, 500] {
            let transport = FakeTransport { _ in .json(code, #"{"error":"synthetic read failure","code":"queue_item_too_large"}"#) }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).queueItem(run: "r1", itemID: "q1")
                XCTFail("expected read failure")
            } catch {}
            XCTAssertEqual(transport.requests.map(\.request.method), ["GET"])
        }
        let wrong = try goJSON(detail(item("full", id: "another-id")))
        let transport = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: wrong, reusable: true) }
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: transport).queueItem(run: "r1", itemID: "q1")
            XCTFail("expected wrong-ID failure")
        } catch {}
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testUnknownRepresentationKeepsAttemptAndDoesNotAutomaticallyRepeat() async throws {
        let transport = FakeTransport { _ in .json(200, #"{"delivered":true,"queue":{"items":[]}}"#) }
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        let message = ArgoOutgoingMessage(run: "r1", text: "original", target: nil, attempt: "ios-original-attempt")
        do { _ = try await connection.send(message); XCTFail("expected unknown representation") }
        catch let error as ArgoClientError { XCTAssertTrue(error.mayHaveBeenDelivered) }
        XCTAssertEqual(transport.requests.count, 1)
        transport.respond = { _ in .queuePreview(200, #"{"delivered":false,"item":{"id":"q1","text":"original","deliveryUnknown":"held"},"queue":{"run":"r1","items":[]}}"#, headers: [("X-Loom-Duplicate", "1")]) }
        let replay = try await connection.send(message) // explicit caller action, same original attempt
        XCTAssertTrue(replay.duplicate)
        XCTAssertEqual(replay.attempt, message.attempt)
        XCTAssertEqual(transport.requests.map { $0.request.header("X-Loom-Attempt") }, [message.attempt, message.attempt])
        XCTAssertEqual(transport.requests.map(\.request.target), ["/api/agents/r1/queue?bounded=1", "/api/agents/r1/queue?bounded=1"])
        XCTAssertEqual(transport.requests[0].request.body, transport.requests[1].request.body)
    }
}
