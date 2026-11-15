import XCTest
@testable import ArgoMobileKit

final class ArgoPushTests: XCTestCase {
    func testOnlyCurrentPairedRegistrationCanRoute() throws {
        let host = Fixture.host()
        let receipt = ArgoPushRegistration(enabled: true, hostID: host.id, deviceID: host.deviceID, registrationID: "registration1")
        let body: [String: Any] = ["v": 1, "hostID": host.id.uuidString, "deviceID": host.deviceID,
            "registrationID": "registration1", "workspace": "w1", "run": "run1", "event": "agent.question", "eventID": "host/1-event"]
        let route = try XCTUnwrap(ArgoPushRoute.decode(["argo": body]))
        XCTAssertTrue(route.matches(receipt, hosts: [host]))
        XCTAssertFalse(route.matches(receipt, hosts: []))
        XCTAssertFalse(route.matches(.init(enabled: true, hostID: host.id, deviceID: host.deviceID, registrationID: "rotated"), hosts: [host]))
        var other = host; other.deviceID = "repaired"
        XCTAssertFalse(route.matches(receipt, hosts: [other]))
        for (key, value) in [("v", 2 as Any), ("event", "session.send" as Any), ("run", "" as Any),
                             ("workspace", "w\u{0}" as Any), ("hostID", "https://stranger.invalid" as Any)] {
            var invalid = body; invalid[key] = value
            XCTAssertNil(ArgoPushRoute.decode(["argo": invalid]), key)
        }
        XCTAssertNil(ArgoPushRoute.decode(["url": "https://stranger.invalid"]))
    }

    func testDeviceRegistrationUsesOwnCredentialAndNoConversationPost() async throws {
        let host = Fixture.host()
        let t = FakeTransport { req in
            XCTAssertEqual(req.target, "/api/notify/device")
            XCTAssertEqual(req.header("X-Argo-Device-ID"), host.deviceID)
            XCTAssertEqual(req.header("X-Argo-Device-Token"), "synthetic-credential")
            if req.method == "DELETE" { return .json(200, #"{"enabled":false}"#) }
            XCTAssertEqual(req.method, "PUT")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(req.body)) as? [String: String])
            XCTAssertEqual(body["environment"], "sandbox")
            XCTAssertEqual(body["topic"], "dev.argo.ios")
            XCTAssertEqual(body["hostID"], host.id.uuidString)
            XCTAssertNil(body["deviceID"])
            return .json(200, "{\"enabled\":true,\"hostID\":\"\(host.id.uuidString)\",\"deviceID\":\"\(host.deviceID)\",\"registrationID\":\"registration1\"}")
        }
        let client = ArgoConnection(host: host, transport: t)
        let credential = GatewayCredential(device: host.deviceID, token: "synthetic-credential")
        let receipt = try await client.registerNotifications(token: String(repeating: "ab", count: 32), environment: "sandbox", topic: "dev.argo.ios", credential: credential)
        XCTAssertEqual(receipt.registrationID, "registration1")
        try await client.unregisterNotifications(credential: credential)
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertTrue(t.requests.allSatisfy { !$0.reuse && $0.request.method != "POST" })
    }

    func testLostRegistrationResponseIsReportedWithoutAutomaticRetry() async {
        let t = FakeTransport { _ in throw TransportFailure.noReply("synthetic lost response") }
        let client = ArgoConnection(host: Fixture.host(), transport: t)
        do {
            _ = try await client.registerNotifications(token: String(repeating: "ab", count: 32), environment: "sandbox", topic: "dev.argo.ios", credential: .init(device: "dev123", token: "synthetic"))
            XCTFail("expected failure")
        } catch { XCTAssertEqual(t.requests.count, 1) }
    }
}
