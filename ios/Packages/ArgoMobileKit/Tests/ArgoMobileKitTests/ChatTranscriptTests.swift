import XCTest
@testable import ArgoMobileKit

final class ChatTranscriptTests: XCTestCase {
    private func position(_ record: Int64, _ block: Int = 0) -> ArgoChatPosition {
        ArgoChatPosition(recordOffset: record, blockIndex: block)
    }

    private func page(_ json: String) throws -> ArgoChatPage {
        XCTAssertLessThanOrEqual(json.utf8.count, ArgoChatPage.responseByteLimit)
        return try JSONDecoder().decode(ArgoChatPage.self, from: Data(json.utf8))
    }

    func testLatestThenOlderThenTail() throws {
        var t = ChatTranscript()
        XCTAssertEqual(t.nextCursor, .latest)
        let latest = try page(Fixture.chat(start: 200, end: 400, items: [Fixture.item("c", offset: 200), Fixture.item("d", offset: 300)].joined(separator: ",")))
        XCTAssertEqual(t.apply(latest, cursor: .latest), .updated)
        XCTAssertEqual(t.items.map(\.id), ["200:0", "300:0"])
        XCTAssertEqual(t.olderCursor, .before(position(200)))
        XCTAssertEqual(t.nextCursor, .after(position(400)))
        let older = try page(Fixture.chat(start: 0, end: 200, items: [Fixture.item("a", offset: 0), Fixture.item("b", offset: 100)].joined(separator: ",")))
        XCTAssertEqual(t.apply(older, cursor: .before(position(200))), .updated)
        XCTAssertEqual(t.items.map(\.id), ["0:0", "100:0", "200:0", "300:0"])
        XCTAssertFalse(t.hasOlder)
        XCTAssertFalse(t.newer, "an older page must not overwrite the retained tail's newer flag")
        let tail = try page(Fixture.chat(start: 400, end: 500, size: 500, items: Fixture.item("e", offset: 400)))
        XCTAssertEqual(t.apply(tail, cursor: .after(position(400))), .updated)
        XCTAssertEqual(t.items.map(\.id), ["0:0", "100:0", "200:0", "300:0", "400:0"])
        XCTAssertEqual(t.end, position(500))
        XCTAssertFalse(t.newer)
        let empty = try page(Fixture.chat(start: 500, end: 500, size: 500, items: ""))
        XCTAssertEqual(t.apply(empty, cursor: .after(position(500))), .updated)
        XCTAssertEqual(t.items.count, 5)
    }

    func testAnotherSessionIsNeverMerged() throws {
        var t = ChatTranscript()
        t.apply(try page(Fixture.chat(items: Fixture.item("a", offset: 100))), cursor: .latest)
        let other = try page(Fixture.chat(session: "s2", start: 400, end: 500, size: 500, items: Fixture.item("x", offset: 400)))
        XCTAssertEqual(t.apply(other, cursor: .after(position(400))), .sessionChanged)
        XCTAssertTrue(t.isEmpty)
        XCTAssertNil(t.identity)
        XCTAssertEqual(t.nextCursor, .latest)
    }

    func testWaitingClearsAndReports() throws {
        var t = ChatTranscript()
        t.apply(try page(Fixture.chat(items: Fixture.item("a", offset: 100))), cursor: .latest)
        let waiting = try page(#"{"bounded":true,"byteLimit":1048576,"waiting":"native record pending","items":[]}"#)
        XCTAssertEqual(t.apply(waiting, cursor: .after(position(400))), .waiting("native record pending"))
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.waiting, "native record pending")
    }

    func testBlockCountBoundAndEvictionCursorsInsideOneRecord() throws {
        var t = ChatTranscript(limit: 3)
        let first = (0..<2).map { Fixture.item("same-id", offset: 0, block: $0) }.joined(separator: ",")
        t.apply(try page(Fixture.chat(start: 0, end: 0, size: 1000, endBlock: 2, items: first)), cursor: .latest)
        let second = (2..<4).map { Fixture.item("same-id", offset: 0, block: $0) }.joined(separator: ",")
        t.apply(try page(Fixture.chat(start: 0, end: 0, size: 1000, startBlock: 2, endBlock: 4, items: second)), cursor: .after(position(0, 2)))
        XCTAssertEqual(t.items.map(\.id), ["0:1", "0:2", "0:3"])
        XCTAssertEqual(t.olderCursor, .before(position(0, 1)))
        let old = try page(Fixture.chat(start: 0, end: 0, size: 1000, endBlock: 1, items: Fixture.item("same-id", offset: 0)))
        t.apply(old, cursor: .before(position(0, 1)))
        XCTAssertEqual(t.items.map(\.id), ["0:0", "0:1", "0:2"])
        XCTAssertEqual(t.nextCursor, .after(position(0, 3)), "first removed block is re-readable")
    }

    func testAll901BlocksCanBeReadBackwardAndForwardWithoutLossOrDuplicate() throws {
        let blocks = (0..<901).map { i in
            Fixture.item("shortened-id", offset: 0, block: i, text: "block-\(i)",
                         type: ["message", "thinking", "tool", "result"][i % 4],
                         extra: ["truncated": true, "truncatedFields": ["id"]])
        }
        let ranges = [0..<1, 1..<301, 301..<601, 601..<901]
        func slice(_ range: Range<Int>) throws -> ArgoChatPage {
            try page(Fixture.chat(start: 0, end: range.upperBound == 901 ? 1000 : 0, size: 1000,
                                  startBlock: range.lowerBound, endBlock: range.upperBound == 901 ? 0 : range.upperBound,
                                  items: blocks[range].joined(separator: ",")))
        }
        var backward = ChatTranscript(limit: 2000)
        backward.apply(try slice(ranges[3]), cursor: .latest)
        for range in ranges.dropLast().reversed() {
            let cursor = try XCTUnwrap(backward.olderCursor)
            XCTAssertEqual(backward.apply(try slice(range), cursor: cursor), .updated)
        }
        XCTAssertEqual(backward.items.map(\.text), (0..<901).map { "block-\($0)" })
        XCTAssertEqual(Set(backward.items.map(\.id)).count, 901)
        XCTAssertFalse(backward.hasOlder)
        XCTAssertFalse(backward.newer)
        XCTAssertTrue(backward.items.allSatisfy { $0.truncated && $0.truncatedFields == ["id"] })
        var forward = ChatTranscript(limit: 2000)
        forward.apply(try slice(ranges[0]), cursor: .around(.zero))
        for range in ranges.dropFirst() {
            let cursor = forward.nextCursor
            XCTAssertEqual(forward.apply(try slice(range), cursor: cursor), .updated)
        }
        XCTAssertEqual(forward.items, backward.items)
    }

    func testByteWindowBoundsBothDirectionsAndRereadsEvictedBlocks() throws {
        let text = String(repeating: "x", count: 60 * 1024)
        let blocks = (0..<16).map { Fixture.item("b\($0)", offset: 0, block: $0, text: text,
                                                  type: "tool", extra: ["output": text]) }
        func slice(_ range: Range<Int>) throws -> ArgoChatPage {
            try page(Fixture.chat(start: 0, end: 0, size: 1000, startBlock: range.lowerBound,
                                  endBlock: range.upperBound, items: blocks[range].joined(separator: ",")))
        }
        var t = ChatTranscript(limit: 1000, byteLimit: 1_048_576)
        t.apply(try slice(0..<8), cursor: .latest)
        XCTAssertEqual(t.items.count, 8)
        t.apply(try slice(8..<16), cursor: t.nextCursor)
        XCTAssertLessThanOrEqual(t.retainedBytes, t.byteLimit)
        XCTAssertEqual(t.items.map(\.cursor.blockIndex), Array(8..<16))
        XCTAssertEqual(t.olderCursor, .before(position(0, 8)))
        t.apply(try slice(0..<8), cursor: try XCTUnwrap(t.olderCursor))
        XCTAssertLessThanOrEqual(t.retainedBytes, t.byteLimit)
        XCTAssertEqual(t.items.map(\.cursor.blockIndex), Array(0..<8))
        XCTAssertEqual(t.nextCursor, .after(position(0, 8)))
        XCTAssertTrue(t.newer)
        t.apply(try slice(8..<16), cursor: t.nextCursor)
        XCTAssertEqual(t.items.map(\.cursor.blockIndex), Array(8..<16))
        XCTAssertLessThanOrEqual(t.retainedBytes, t.byteLimit)
    }

    func testEmptyScannedSpansAdvanceCursors() throws {
        var t = ChatTranscript()
        t.apply(try page(Fixture.chat(start: 20, end: 40, size: 80, items: "")), cursor: .latest)
        t.apply(try page(Fixture.chat(start: 40, end: 60, size: 80, items: "")), cursor: t.nextCursor)
        XCTAssertEqual(t.nextCursor, .after(position(60)))
        t.apply(try page(Fixture.chat(start: 0, end: 20, size: 80, items: "")), cursor: try XCTUnwrap(t.olderCursor))
        XCTAssertEqual(t.start, .zero)
        XCTAssertEqual(t.end, position(60))
        XCTAssertTrue(t.newer)
    }

    func testStaleResponseCannotCreateAHoleAfterWindowEviction() throws {
        var t = ChatTranscript(limit: 3)
        let initial = (6..<9).map { Fixture.item("b", offset: 0, block: $0) }.joined(separator: ",")
        t.apply(try page(Fixture.chat(start: 0, end: 1000, size: 1000, startBlock: 6, items: initial)), cursor: .latest)
        let inFlight = t.nextCursor
        let older = (0..<6).map { Fixture.item("b", offset: 0, block: $0) }.joined(separator: ",")
        t.apply(try page(Fixture.chat(start: 0, end: 0, size: 1000, endBlock: 6, items: older)), cursor: try XCTUnwrap(t.olderCursor))
        let kept = t
        let later = try page(Fixture.chat(start: 1000, end: 1200, size: 1200, items: Fixture.item("later", offset: 1000)))
        XCTAssertEqual(t.apply(later, cursor: inFlight), .stalePage)
        XCTAssertEqual(t, kept)
    }

    func testToolResultAndTruncationFieldsSurvivePaging() throws {
        var t = ChatTranscript()
        let tool = Fixture.item("call", offset: 100, type: "tool", extra: ["call": "c1", "diff": "-old\n+new", "cwd": "/fixture", "truncated": true, "truncatedFields": ["diff", "output"]])
        let result = Fixture.item("result", offset: 100, block: 1, role: "tool", text: "result text", type: "result",
                                  extra: ["call": "c1", "output": "command output", "failed": true, "exit": 2])
        t.apply(try page(Fixture.chat(items: tool + "," + result)), cursor: .latest)
        XCTAssertEqual(t.items.map(\.type), ["tool", "result"])
        XCTAssertEqual(t.items.map(\.call), ["c1", "c1"])
        XCTAssertEqual(t.items[0].diff, "-old\n+new")
        XCTAssertEqual(t.items[0].cwd, "/fixture")
        XCTAssertTrue(t.items[0].truncated)
        XCTAssertEqual(t.items[0].truncatedFields, ["diff", "output"])
        XCTAssertEqual(t.items[1].output, "command output")
        XCTAssertTrue(t.items[1].failed)
        XCTAssertEqual(t.items[1].exit, 2)
        XCTAssertFalse(t.items[1].truncated)
    }

    func testCanonicalCursorValidation() throws {
        for raw in ["0:0", "12345:901", "9223372036854775807:0"] {
            let value = try XCTUnwrap(ArgoChatPosition(rawValue: raw))
            XCTAssertEqual(value.description, raw)
            XCTAssertEqual(try JSONDecoder().decode(ArgoChatPosition.self, from: JSONEncoder().encode(value)), value)
        }
        for raw in ["0", "-1:0", "1:-1", "01:0", "0:00", "1:2:3", "9223372036854775808:0", "1:2\n"] {
            XCTAssertNil(ArgoChatPosition(rawValue: raw), raw)
        }
        XCTAssertThrowsError(try page(Fixture.chat(items: Fixture.item("x", offset: 100, extra: ["cursor": "99:0"]))))
    }
}
