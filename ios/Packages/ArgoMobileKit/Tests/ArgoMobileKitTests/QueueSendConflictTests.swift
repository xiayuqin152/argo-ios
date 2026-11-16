import XCTest
@testable import ArgoMobileKit

final class QueueSendConflictTests: XCTestCase {
    private let run = "20261115-101010-abcdef01"

    func testQueueConflictAfterPasteRetainsHostExplanationAsUnknown() async throws {
        let explanation = "粘贴之后 Agent 弹出了对话框，回车没有发送；请在终端里查看"
        let transport = FakeTransport { _ in
            .json(409, #"{"bounded":true,"byteLimit":8388608,"error":"粘贴之后 Agent 弹出了对话框，回车没有发送；请在终端里查看"}"#)
        }
        let identity = ArgoAgentIdentity(run: run, engine: "claude", session: "original-session")
        let message = ArgoOutgoingMessage(run: run, text: "Synthetic original message", target: identity, attempt: "ios-conflict-original")
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: transport).send(message)
            XCTFail("expected an unknown queue delivery")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .deliveryUnknown(.detail(explanation)))
            XCTAssertTrue(error.mayHaveBeenDelivered)
        }
        let sent = try XCTUnwrap(transport.requests.first?.request)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(sent.target, "/api/agents/\(run)/queue?bounded=1")
        XCTAssertEqual(sent.header("X-Loom-Attempt"), message.attempt)
        XCTAssertEqual(sent.json["text"] as? String, message.text)
        XCTAssertEqual(sent.json["when"] as? String, "auto")
        XCTAssertEqual(sent.json["submit"] as? Bool, true)
        XCTAssertEqual((sent.json["target"] as? [String: Any])?["session"] as? String, identity.session)
    }

    func testQueueConflictNeedsNoMessageKeywordOrCode() async {
        let transport = FakeTransport { _ in
            .json(409, #"{"error":"Synthetic conflict","detail":"Original host detail\nSecond line","code":"future-conflict"}"#)
        }
        do {
            _ = try await ArgoConnection(host: Fixture.host(), transport: transport).send(
                ArgoOutgoingMessage(run: run, text: "Synthetic message", target: nil))
            XCTFail("expected an unknown queue delivery")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .deliveryUnknown(.detail("Synthetic conflict\nOriginal host detail\nSecond line")))
            XCTAssertTrue(error.mayHaveBeenDelivered)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testReadReplyAndInterruptKeepTheirOwnConflictContract() async {
        let transport = FakeTransport { _ in
            .json(409, #"{"error":"Synthetic conflict","detail":"Original detail","code":"original-conflict"}"#)
        }
        let connection = ArgoConnection(host: Fixture.host(), transport: transport)
        for operation in 0..<3 {
            do {
                switch operation {
                case 0: _ = try await connection.queue(run: run)
                case 1: _ = try await connection.reply(run: run, terminal: "t1", agent: "", questionID: "q1", text: "Synthetic answer")
                default: _ = try await connection.interrupt(run: run)
                }
                XCTFail("expected a typed HTTP conflict")
            } catch let error as ArgoClientError {
                XCTAssertEqual(error, .http(status: 409, message: "Synthetic conflict\nOriginal detail", code: "original-conflict"))
                XCTAssertFalse(error.mayHaveBeenDelivered)
            } catch { XCTFail("\(error)") }
        }
        XCTAssertEqual(transport.requests.map(\.request.method), ["GET", "POST", "POST"])
        XCTAssertEqual(transport.requests.map(\.request.target), [
            "/api/agents/\(run)/queue?bounded=1", "/api/agents/\(run)/reply", "/api/agents/\(run)/interrupt"
        ])
    }

    func testQueueAuthenticationRefusalsStayTypedAndAreNotRetried() async {
        for status in [401, 403] {
            let transport = FakeTransport { _ in .json(status, #"{"error":"Synthetic denied","code":"denied"}"#) }
            do {
                _ = try await ArgoConnection(host: Fixture.host(), transport: transport).send(
                    ArgoOutgoingMessage(run: run, text: "Synthetic message", target: nil))
                XCTFail("expected an authentication refusal")
            } catch let error as ArgoClientError {
                XCTAssertEqual(error, .http(status: status, message: "Synthetic denied", code: "denied"))
                XCTAssertFalse(error.mayHaveBeenDelivered)
            } catch { XCTFail("\(error)") }
            XCTAssertEqual(transport.requests.count, 1)
        }
    }

    func testSuccessfulPastedReceiptKeepsItsDistinctState() async throws {
        let transport = FakeTransport { _ in
            .queuePreview(200, #"{"delivered":false,"pasted":true,"note":"Synthetic paste waits for Enter","queue":{"run":"20261115-101010-abcdef01","items":[],"later":[]}}"#)
        }
        let receipt = try await ArgoConnection(host: Fixture.host(), transport: transport).send(
            ArgoOutgoingMessage(run: run, text: "Synthetic message", target: nil))
        XCTAssertFalse(receipt.delivered)
        XCTAssertTrue(receipt.pasted)
        XCTAssertEqual(receipt.note, "Synthetic paste waits for Enter")
        XCTAssertEqual(transport.requests.count, 1)
    }
}
