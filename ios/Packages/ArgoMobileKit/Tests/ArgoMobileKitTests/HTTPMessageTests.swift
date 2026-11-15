import XCTest
@testable import ArgoMobileKit

final class HTTPMessageTests: XCTestCase {
    private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testEncodesGetWithLoopbackHostAndNoBody() throws {
        let req = HTTPRequest(method: "GET", target: "/api/agents?ws=w1", headers: [("Authorization", "Bearer t")])
        XCTAssertEqual(text(try req.encoded(keepAlive: true)),
                       "GET /api/agents?ws=w1 HTTP/1.1\r\nHost: 127.0.0.1:3430\r\nAuthorization: Bearer t\r\nConnection: keep-alive\r\n\r\n")
    }

    func testEncodesPostWithLengthAndClose() throws {
        let body = Data(#"{"text":"你好"}"#.utf8)
        let req = HTTPRequest(method: "POST", target: "/api/agents/r1/queue", headers: [("Content-Type", "application/json")], body: body)
        let wire = try req.encoded(keepAlive: false)
        XCTAssertTrue(text(wire).hasPrefix("POST /api/agents/r1/queue HTTP/1.1\r\nHost: 127.0.0.1:3430\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"))
        XCTAssertEqual(wire.suffix(body.count), body)
        let empty = HTTPRequest(method: "POST", target: "/x")
        XCTAssertTrue(text(try empty.encoded(keepAlive: false)).contains("Content-Length: 0\r\n"))
    }

    func testRefusesHeaderInjectionAndBadTargets() {
        XCTAssertThrowsError(try HTTPRequest(method: "GET", target: "/a", headers: [("X", "a\r\nHost: evil")]).encoded(keepAlive: true))
        XCTAssertThrowsError(try HTTPRequest(method: "GET", target: "/a b").encoded(keepAlive: true))
        XCTAssertThrowsError(try HTTPRequest(method: "GET", target: "http://evil/").encoded(keepAlive: true))
        XCTAssertThrowsError(try HTTPRequest(method: "GET", target: "/a", headers: [("Host", "evil")]).encoded(keepAlive: true))
        XCTAssertThrowsError(try HTTPRequest(method: "G ET", target: "/a").encoded(keepAlive: true))
    }

    func testParsesContentLengthAcrossPieces() throws {
        var p = HTTPResponseParser()
        let wire = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8)
        var result: HTTPResponse?
        for byte in wire { result = try p.append(Data([byte])) ?? result }
        let r = try XCTUnwrap(result)
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.header("content-type"), "application/json")
        XCTAssertEqual(text(r.body), "{\"ok\":true}")
        XCTAssertTrue(r.reusable)
    }

    func testParsesChunkedWithExtensionsAndTrailers() throws {
        var p = HTTPResponseParser()
        XCTAssertNil(try p.append(Data("HTTP/1.1 409 Conflict\r\nTransfer-Encoding: chunked\r\n\r\n5;x=y\r\nhel".utf8)))
        XCTAssertNil(try p.append(Data("lo\r\n6\r\n world\r\n0\r\nX-Trailer: 1\r\n".utf8)))
        let r = try XCTUnwrap(try p.append(Data("\r\n".utf8)))
        XCTAssertEqual(r.status, 409)
        XCTAssertEqual(text(r.body), "hello world")
        XCTAssertTrue(r.reusable)
    }

    func testBodyUntilCloseIsNotReusable() throws {
        var p = HTTPResponseParser()
        XCTAssertNil(try p.append(Data("HTTP/1.1 200 OK\r\n\r\nabc".utf8)))
        XCTAssertNil(try p.append(Data("def".utf8)))
        let r = try p.finish()
        XCTAssertEqual(text(r.body), "abcdef")
        XCTAssertFalse(r.reusable)
    }

    func testConnectionCloseAndHTTP10AreNotReusable() throws {
        var a = HTTPResponseParser()
        XCTAssertFalse(try XCTUnwrap(a.append(Data("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8))).reusable)
        var b = HTTPResponseParser()
        XCTAssertFalse(try XCTUnwrap(b.append(Data("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))).reusable)
    }

    func testSkipsInterimContinue() throws {
        var p = HTTPResponseParser()
        let r = try XCTUnwrap(p.append(Data("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No Content\r\nX: y\r\n\r\n".utf8)))
        XCTAssertEqual(r.status, 204)
        XCTAssertEqual(r.headers.map(\.name), ["X"])
        XCTAssertTrue(r.body.isEmpty)
    }

    func testTruncatedAndOversizedAndGarbage() throws {
        var cut = HTTPResponseParser()
        XCTAssertNil(try cut.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)))
        XCTAssertThrowsError(try cut.finish()) { XCTAssertEqual($0 as? HTTPError, .truncated) }

        var big = HTTPResponseParser(maxBody: 4)
        XCTAssertThrowsError(try big.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n".utf8)))

        var bigChunk = HTTPResponseParser(maxBody: 4)
        XCTAssertThrowsError(try bigChunk.append(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n".utf8)))

        var notHTTP = HTTPResponseParser()
        XCTAssertThrowsError(try notHTTP.append(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)))

        var extra = HTTPResponseParser()
        XCTAssertThrowsError(try extra.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nab".utf8)))

        var head = HTTPResponseParser()
        XCTAssertThrowsError(try head.append(Data(repeating: 0x41, count: HTTPResponseParser.maxHead + 1)))
    }

    func testReceivedAnyTracksFirstByte() throws {
        var p = HTTPResponseParser()
        XCTAssertFalse(p.receivedAny)
        _ = try p.append(Data("H".utf8))
        XCTAssertTrue(p.receivedAny)
    }

    func testNoBodyResponsesRejectExtraBytes() {
        for (method, status) in [("GET", "204 No Content"), ("GET", "304 Not Modified"), ("HEAD", "200 OK")] {
            var parser = HTTPResponseParser(headRequest: method == "HEAD")
            let wire = Data("HTTP/1.1 \(status)\r\n\r\nunexpected bytes".utf8)
            XCTAssertThrowsError(try parser.append(wire), "\(method) \(status) must reject extra bytes") {
                guard case HTTPError.malformed = $0 else { return XCTFail("unexpected error: \($0)") }
            }
        }
    }

    func testNoBodyResponsesAcceptValidFragmentedHeaders() throws {
        for (method, status) in [("GET", "204 No Content"), ("GET", "304 Not Modified"), ("HEAD", "200 OK")] {
            var parser = HTTPResponseParser(headRequest: method == "HEAD")
            XCTAssertNil(try parser.append(Data("HTTP/1.1 \(status)\r\nContent-Length: 123\r\n".utf8)))
            let response = try XCTUnwrap(parser.append(Data("\r\n".utf8)))
            XCTAssertTrue(response.body.isEmpty)
            XCTAssertTrue(response.reusable)
        }
    }
}
