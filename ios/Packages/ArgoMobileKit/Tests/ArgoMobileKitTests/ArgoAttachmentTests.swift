import XCTest
@testable import ArgoMobileKit

final class ArgoAttachmentTests: XCTestCase {
    private func file(_ data: Data, name: String = "文 档\"'\\.txt", root: URL? = nil) throws -> ArgoLocalAttachment {
        try ArgoLocalAttachment.create(name: name, mime: "application/octet-stream", kind: .file, root: root) { try data.write(to: $0) }
    }
    private func client(_ transport: FakeTransport) -> ArgoConnection { ArgoConnection(host: Fixture.host(), transport: transport) }
    private func receipt(path: String = "/synthetic/remote/file.txt", name: String = "renamed.txt", size: Int) throws -> HTTPResponse {
        .json(200, String(decoding: try JSONSerialization.data(withJSONObject: [["path": path, "name": name, "size": size]]), as: UTF8.self))
    }

    func testMultipartPreservesExactBinaryFramingAndServerName() async throws {
        let bytes = Data([0, 255, 1, 13, 10]) + Data("\r\n--a-fake-boundary\r\n图片".utf8)
        let local = try file(bytes)
        let transport = FakeTransport { request in
            XCTAssertEqual(request.target, "/api/upload")
            XCTAssertFalse(request.idempotent)
            XCTAssertNil(request.header("X-Loom-Attempt"))
            XCTAssertEqual(request.maxResponseBodyBytes, 64 * 1024)
            let header = try XCTUnwrap(request.header("Content-Type"))
            let boundary = String(try XCTUnwrap(header.components(separatedBy: "boundary=").last))
            let escaped = local.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(escaped)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
            expected.append(bytes); expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
            XCTAssertEqual(request.body, expected)
            let wire = try request.encoded(keepAlive: false)
            XCTAssertNotNil(wire.range(of: Data("Content-Length: \(expected.count)\r\n".utf8)))
            return try self.receipt(size: bytes.count)
        }
        let uploaded = try await client(transport).uploadAttachment(local)
        XCTAssertEqual(uploaded.path, "/synthetic/remote/file.txt")
        XCTAssertEqual(uploaded.name, "renamed.txt")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertFalse(transport.requests[0].reuse)
        XCTAssertEqual(transport.requests[0].request.header("Authorization"), "Bearer " + String(repeating: "a", count: 64))
    }

    func testZeroAndExactLimitAreAcceptedAndOversizeOrChangedLocalAreRefused() async throws {
        for count in [0, ArgoAttachmentPolicy.byteLimit] {
            let local = try file(Data(repeating: 0x5a, count: count))
            let transport = FakeTransport { _ in try self.receipt(size: count) }
            let uploaded = try await client(transport).uploadAttachment(local)
            XCTAssertEqual(uploaded.size, count)
        }
        XCTAssertThrowsError(try file(Data(repeating: 0x5a, count: ArgoAttachmentPolicy.byteLimit + 1)))
        let local = try file(Data([1, 2, 3]))
        try Data([1, 2]).write(to: local.url)
        let transport = FakeTransport()
        do { _ = try await client(transport).uploadAttachment(local); XCTFail("staged mutation accepted") }
        catch { XCTAssertEqual(transport.requests.count, 0) }
    }

    func testInvalidReceiptsNeverBecomeReferences() async throws {
        let local = try file(Data([1, 2, 3]))
        let valid = try receipt(size: 3)
        let malformed: [HTTPResponse] = [
            .json(200, "[]"), .json(200, "{}"),
            .json(200, "[" + String(decoding: valid.body, as: UTF8.self).dropFirst().dropLast() + "," + String(decoding: valid.body, as: UTF8.self).dropFirst().dropLast() + "]"),
            try receipt(path: "relative", size: 3), try receipt(path: "/bad\npath", size: 3),
            try receipt(path: "/" + String(repeating: "x", count: 4096), size: 3),
            try receipt(name: "../bad", size: 3), try receipt(name: "..", size: 3), try receipt(name: "bad\u{7f}", size: 3),
            try receipt(size: -1), try receipt(size: 2),
            .json(200, String(repeating: "x", count: 64 * 1024 + 1))
        ]
        for response in malformed {
            let transport = FakeTransport { _ in response }
            do { _ = try await client(transport).uploadAttachment(local); XCTFail("accepted \(response.body.count)-byte invalid receipt") }
            catch { XCTAssertEqual(transport.requests.count, 1) }
        }
    }

    func testUploadFailureNeverAutomaticallyRetriesIncluding401AndLostReceipt() async throws {
        let local = try file(Data([1]))
        for status in [401, 403, 413, 429, 500, 507] {
            let transport = FakeTransport { _ in .json(status, #"{"error":"specific upload refusal"}"#) }
            do { _ = try await client(transport).uploadAttachment(local); XCTFail("expected HTTP refusal") }
            catch let e as ArgoClientError {
                guard case .http(let actual, let message, _) = e else { return XCTFail("\(e)") }
                XCTAssertEqual(actual, status); XCTAssertEqual(message, "specific upload refusal")
            }
            XCTAssertEqual(transport.requests.count, 1)
        }
        let lost = FakeTransport { _ in throw TransportFailure.noReply("upload receipt lost") }
        do { _ = try await client(lost).uploadAttachment(local); XCTFail("expected loss") } catch {}
        XCTAssertEqual(lost.requests.count, 1)
    }

    func testDownloadScopesEncodingLimitAndRealErrorStatusesWithoutRedirect() async throws {
        let path = "/合成/a b&\"?#.pdf"
        let ref = try ArgoFileReference(path: path, name: "a.pdf")
        let transport = FakeTransport { request in
            XCTAssertEqual(request.maxResponseBodyBytes, ArgoAttachmentPolicy.byteLimit)
            let query = URLComponents(string: "http://synthetic.invalid" + request.target)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "path" }?.value, path)
            XCTAssertEqual(query?.first { $0.name == "ws" }?.value, "w &1")
            XCTAssertEqual(query?.first { $0.name == "terminal" }?.value, "t/1")
            return HTTPResponse(status: 200, headers: [], body: Data([0, 255]), reusable: true)
        }
        let bytes = try await client(transport).downloadAttachment(ref, workspace: "w &1", terminal: "t/1")
        XCTAssertEqual(bytes, Data([0, 255]))
        for status in [302, 403, 404, 413] {
            let t = FakeTransport { _ in .json(status, #"{"error":"actual remote state"}"#, headers: [("Location", "https://synthetic.invalid/file")]) }
            do { _ = try await client(t).downloadAttachment(ref, workspace: "w", terminal: "t"); XCTFail("expected actual status") }
            catch let e as ArgoClientError { guard case .http(let actual, _, _) = e else { return XCTFail("\(e)") }; XCTAssertEqual(actual, status) }
            XCTAssertEqual(t.requests.count, 1)
            XCTAssertTrue(t.requests[0].request.target.hasPrefix("/api/download?"))
        }
        for handler: (HTTPRequest) throws -> HTTPResponse in [
            { _ in throw HTTPError.tooLarge("synthetic oversized response") },
            { _ in HTTPResponse(status: 200, headers: [], body: Data(repeating: 0, count: ArgoAttachmentPolicy.byteLimit + 1), reusable: true) }
        ] {
            let t = FakeTransport(respond: handler)
            do { _ = try await client(t).downloadAttachment(ref, workspace: "w", terminal: "t"); XCTFail("oversize accepted") }
            catch { XCTAssertEqual(error as? ArgoClientError, ArgoAttachmentPolicy.tooLarge) }
        }
        var parser = HTTPResponseParser(maxBody: ArgoAttachmentPolicy.byteLimit)
        XCTAssertThrowsError(try parser.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 10485761\r\n\r\n".utf8)))
        let boundary = FakeTransport { _ in HTTPResponse(status: 200, headers: [], body: Data(repeating: 0, count: ArgoAttachmentPolicy.byteLimit), reusable: true) }
        let limitBytes = try await client(boundary).downloadAttachment(ref, workspace: "w", terminal: "t")
        XCTAssertEqual(limitBytes.count, ArgoAttachmentPolicy.byteLimit)
        let longRef = try ArgoFileReference(path: "/" + String(repeating: "图", count: 1365), name: "Photo.jpg")
        _ = try await client(boundary).downloadAttachment(longRef, workspace: "w", terminal: "t")
    }

    func testReferencesAreStrictBoundedAndIncludedInTranscriptBudget() throws {
        let ref = ["path": "/" + String(repeating: "p", count: 4000), "name": "file.txt", "origin": "text-reference"]
        func page(_ refs: [[String: String]], block: Int = 0) throws -> ArgoChatPage {
            try JSONDecoder().decode(ArgoChatPage.self, from: Data(Fixture.chat(start: 0, end: 0, size: 100, startBlock: block, endBlock: block + 1,
                items: Fixture.item("i", offset: 0, block: block, extra: ["fileRefs": refs])).utf8))
        }
        XCTAssertThrowsError(try page(Array(repeating: ref, count: 21)))
        for (field, value) in [("path", "relative"), ("path", "/a\u{0}"), ("path", "/" + String(repeating: "图", count: 1366)), ("origin", "native-image")] {
            var bad = ref; bad[field] = value
            XCTAssertThrowsError(try page([bad]))
        }
        let joinedEmoji = try page([["path": "/work/👩‍💻.txt", "name": "👩‍💻.txt", "origin": "text-reference"]])
        XCTAssertEqual(joinedEmoji.items.first?.fileRefs.first?.name, "👩‍💻.txt")
        let emojiFile = try file(Data([1]), name: "👩‍💻.txt")
        XCTAssertEqual(emojiFile.name, "👩‍💻.txt")
        let root = try page([["path": "/", "name": "/", "origin": "text-reference"]])
        XCTAssertEqual(root.items.first?.fileRefs.first?.name, "/", "a valid directory mention must not poison native chat")
        let withRefs = try page(Array(repeating: ref, count: 20))
        let without = try page([])
        XCTAssertGreaterThan(withRefs.items[0].retainedByteCount - without.items[0].retainedByteCount, 80_000)
        var transcript = ChatTranscript(limit: 600)
        for i in 0..<70 {
            let p = try page(Array(repeating: ref, count: 20), block: i)
            transcript.apply(p, cursor: i == 0 ? .latest : transcript.nextCursor)
            XCTAssertLessThanOrEqual(transcript.retainedBytes, 4 * 1_048_576)
        }
        XCTAssertGreaterThan(transcript.start.blockIndex, 0)
        XCTAssertEqual(transcript.retainedBytes, transcript.items.reduce(0) { $0 + $1.retainedByteCount })
        let linked = try ArgoFileReference(path: "/synthetic/a b.pdf", name: "server name.pdf")
        XCTAssertNil(try ArgoFileReference.link(URL(string: "https://synthetic.invalid/image")!, references: []))
        XCTAssertEqual(try ArgoFileReference.link(URL(fileURLWithPath: linked.path), references: [linked]), linked)
        for value in ["file://other-host/synthetic/a.pdf", "file://user@localhost/synthetic/a.pdf", "file://localhost:80/synthetic/a.pdf", "file:///synthetic/a.pdf?token=x", "file:///synthetic/a.pdf#fragment"] {
            XCTAssertThrowsError(try ArgoFileReference.link(URL(string: value)!, references: [linked]))
        }
    }

    func testBodyLinksRequireExactMessageReference() throws {
        let literal = try ArgoFileReference(path: "/work/a%2Fb 中.txt", name: "source name.txt")
        let slash = try ArgoFileReference(path: "/work/a/b 中.txt", name: "different file.txt")
        let url = URL(string: "file:///work/a%252Fb%20%E4%B8%AD.txt")!
        XCTAssertEqual(try ArgoFileReference.link(url, references: [slash, literal]), literal)
        XCTAssertThrowsError(try ArgoFileReference.link(url, references: [slash]))
        XCTAssertThrowsError(try ArgoFileReference.link(url, references: []))

        let nfc = try ArgoFileReference(path: "/work/caf\u{e9}.txt", name: "NFC")
        let nfd = try ArgoFileReference(path: "/work/cafe\u{301}.txt", name: "NFD")
        let nfcURL = URL(fileURLWithPath: nfc.path)
        let nfdURL = URL(fileURLWithPath: nfd.path)
        XCTAssertEqual(try ArgoFileReference.link(nfcURL, references: [nfd, nfc])?.name, "NFC")
        XCTAssertEqual(try ArgoFileReference.link(nfdURL, references: [nfc, nfd])?.name, "NFD")
        XCTAssertThrowsError(try ArgoFileReference.link(nfcURL, references: [nfd]))
        XCTAssertThrowsError(try ArgoFileReference.link(nfdURL, references: [nfc]))
        for value in ["file:///work/a%00b.txt", "file:////remote/a", "file:///work/a%1Bb.txt"] {
            XCTAssertThrowsError(try ArgoFileReference.link(URL(string: value)!, references: [literal]))
        }
    }

    func testOwnedDirectoryCleanupAndOrdinaryFileRules() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("argo-owned-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data([7]).write(to: unrelated)
        var owned: ArgoLocalAttachment? = try file(Data([1]), root: root)
        let directory = try XCTUnwrap(owned).url.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        owned = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertThrowsError(try ArgoLocalAttachment.copy(root, name: "folder", root: root))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelated)
        XCTAssertThrowsError(try ArgoLocalAttachment.copy(link, name: "link", root: root))
        XCTAssertThrowsError(try file(Data(), name: "..", root: root))
    }
}
