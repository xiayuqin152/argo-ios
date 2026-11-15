import XCTest
@testable import ArgoMobileKit

final class ArgoConnectionTests: XCTestCase {
    private let run = "20261115-101010-abcdef01"

    private func connection(_ transport: FakeTransport) -> ArgoConnection {
        ArgoConnection(host: Fixture.host(), transport: transport)
    }

    func testConnectReadsTokenThenHealthWithBearerOnly() async throws {
        let t = FakeTransport { req in
            XCTAssertEqual(req.target, "/api/health")
            return .json(200, Fixture.health)
        }
        let info = try await connection(t).connect()
        XCTAssertEqual(info.version, "1.0.12")
        XCTAssertEqual(info.api, 1)
        XCTAssertEqual(info.machine, "devbox")
        let sent = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(sent.request.header("Authorization"), "Bearer " + String(repeating: "a", count: 64))
        XCTAssertNil(sent.request.header("Origin"), "Bearer requests need no Origin (internal/auth Wrap)")
        XCTAssertTrue(sent.reuse)
        XCTAssertEqual(t.tokenCalls, 1)
    }

    func testConnectRefusesTooOldLoomd() async {
        let t = FakeTransport { _ in .json(200, #"{"version":"1.0.9"}"#) }
        do {
            _ = try await connection(t).connect()
            XCTFail("expected refusal")
        } catch let error as ArgoClientError {
            guard case .unsupportedServer(let text) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(text, .message("Argo on %@ uses protocol %@; this app requires %@ or later. Connect with Argo for Mac to update the host.", arguments: ["dev", "0", String(LoomdAPI.minimum)]))
        } catch { XCTFail("\(error)") }
    }

    func testAttentionToleratesNullOptions() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.attention) }
        let snap = try await connection(t).attention()
        XCTAssertEqual(snap.waiting.count, 2)
        XCTAssertEqual(snap.waiting[0].options, [])
        XCTAssertFalse(snap.waiting[0].acceptsReply)
        XCTAssertEqual(snap.waiting[1].options, ["A", "B"])
        XCTAssertTrue(snap.waiting[1].acceptsReply)
        XCTAssertEqual(snap.agents?.first?.state, "waiting")
    }

    func testAgentsQueryEscapesWorkspaceAndFiltersOtherWorkspaces() async throws {
        let t = FakeTransport { req in
            .json(200, req.target == "/api/terminals?ws=w1" ? #"[{"id":"t1","ws":"w1","agent":{"run":"20261115-101010-abcdef01"}}]"# : Fixture.cards)
        }
        let cards = try await connection(t).agents(workspace: "w1")
        XCTAssertEqual(Set(t.requests.map(\.request.target)), Set(["/api/agents?ws=w1", "/api/terminals?ws=w1"]))
        XCTAssertEqual(cards.map(\.run), [run])
        let card = try XCTUnwrap(cards.first)
        XCTAssertEqual(card.ask?.options, ["A", "B"])
        XCTAssertEqual(card.ask?.acceptsReply, true)
        XCTAssertEqual(card.plan?.items.map(\.isActive), [false, true])
        XCTAssertEqual(card.queued, 2)
        XCTAssertEqual(card.attention, 5)
        XCTAssertEqual(card.waitingIDs, ["q2"])

        let t2 = FakeTransport { req in
            .json(200, req.target == "/api/terminals?ws=a%20b%26c" ? "[]" : "null")
        }
        let none = try await connection(t2).agents(workspace: "a b&c")
        XCTAssertEqual(Set(t2.requests.map(\.request.target)), Set(["/api/agents?ws=a%20b%26c", "/api/terminals?ws=a%20b%26c"]))
        XCTAssertEqual(none, [])
    }

    func testAgentsMergesOnlyReadableHandStartedSessions() async throws {
        let terminals = #"""
        [{"id":"t1","ws":"w1","agent":{"run":"20261115-101010-abcdef01"}},
         {"id":"plain","ws":"w1","title":"Shell","created":"2026-11-15T10:00:00Z","unmanaged":null},
         {"id":"ta","ws":"w1","title":"Terminal title","created":"2026-11-15T10:00:00Z","unmanaged":{"engine":"claude","name":"Claude Code","cwd":"/src","title":"Manual CLI","state":"waiting","stateText":"Needs answer","stateAt":"2026-11-15T10:10:10Z","attention":5,"unread":true,"waitingIDs":["u1"]}},
         {"id":"other","ws":"w2","title":"Other","created":"2026-11-15T10:00:00Z","unmanaged":{"engine":"codex","state":"done","stateAt":"2026-11-15T10:10:10Z"}}]
        """#
        let t = FakeTransport { req in .json(200, req.target == "/api/terminals?ws=w1" ? terminals : Fixture.cards) }
        let cards = try await connection(t).agents(workspace: "w1")
        XCTAssertEqual(cards.map(\.run), [run, "unmanaged:ta"], "managed cards stay intact; plain shells stay out")
        let manual = try XCTUnwrap(cards.last)
        XCTAssertEqual(manual.terminal, "ta")
        XCTAssertEqual(manual.displayTitle, "Manual CLI")
        XCTAssertEqual(manual.cli, "Claude Code")
        XCTAssertEqual(manual.engine, "claude")
        XCTAssertEqual(manual.stateText, "Needs answer")
        XCTAssertEqual(manual.waitingIDs, ["u1"])
        XCTAssertNil(manual.ask, "a hand-started CLI has no managed-run reply")
        XCTAssertEqual(manual.attention, 5)
        XCTAssertEqual(manual.cwd, "/src")
        XCTAssertTrue(manual.unread)
    }

    func testSeenUsesExactDestinationAndQuestionIDs() async throws {
        let t = FakeTransport { _ in .json(200, "{}") }
        let c = connection(t)
        try await c.markAgentSeen(run: run, waitingIDs: ["q1", "q2"])
        try await c.markTerminalSeen(terminal: "t/1", waitingIDs: ["u1"])
        XCTAssertEqual(t.requests.map(\.request.target), ["/api/agents/\(run)/seen", "/api/terminals/t%2F1/seen"])
        XCTAssertEqual(t.requests.map(\.request.method), ["POST", "POST"])
        XCTAssertEqual(t.requests[0].request.json["waitingIDs"] as? [String], ["q1", "q2"])
        XCTAssertEqual(t.requests[1].request.json["waitingIDs"] as? [String], ["u1"])
        XCTAssertNil(t.requests[0].request.header("X-Loom-Attempt"))
        await assertRefused { _ = try await c.markAgentSeen(run: "unmanaged:t9", waitingIDs: []) }
        await assertRefused { _ = try await c.markTerminalSeen(terminal: "", waitingIDs: []) }
        XCTAssertEqual(t.requests.count, 2)
    }

    func testSeenRetriesTheSameExactMarkerAfter401() async throws {
        let first = String(repeating: "a", count: 64), second = String(repeating: "c", count: 64)
        let t = FakeTransport(tokens: [first, second]) { req in
            req.header("Authorization") == "Bearer \(first)" ? .json(401, #"{"error":"需要访问口令"}"#) : .json(200, "{}")
        }
        try await connection(t).markAgentSeen(run: run, waitingIDs: ["q1"])
        XCTAssertEqual(t.requests.count, 2)
        XCTAssertEqual(t.requests.map { $0.request.json["waitingIDs"] as? [String] }, [["q1"], ["q1"]])
    }

    func testTeamViewDecodesProgressWithNullSlices() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.team) }
        let team = try await connection(t).team(run: run)
        XCTAssertEqual(t.requests.first?.request.target, "/api/agents/\(run)")
        XCTAssertEqual(team.userTurns, [])
        XCTAssertEqual(team.tasks.first?.title, "Write tests")
        XCTAssertEqual(team.steps.first?.mark, "edit")
        XCTAssertEqual(team.plan?.total, 1)
        XCTAssertEqual(team.state, "working")
        let ask = try XCTUnwrap(team.asks.first)
        XCTAssertEqual(ask.risk, "destructive")
        XCTAssertFalse(ask.acceptsReply)
    }

    func testChatCursorsAndSession() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.chat(items: Fixture.item("a", offset: 100))) }
        let c = connection(t)
        let page = try await c.chat(terminal: "t1")
        _ = try await c.chat(terminal: "t1", cursor: .before(.init(recordOffset: 100, blockIndex: 301)), session: "s1")
        _ = try await c.chat(terminal: "t1", cursor: .after(.init(recordOffset: 400)), session: "s1")
        _ = try await c.chat(terminal: "t/1", cursor: .latest, session: "s1")
        XCTAssertEqual(t.requests.map(\.request.target), [
            "/api/terminals/t1/chat?bounded=1",
            "/api/terminals/t1/chat?before=100%3A301&bounded=1&session=s1",
            "/api/terminals/t1/chat?after=400%3A0&bounded=1&session=s1",
            "/api/terminals/t%2F1/chat?bounded=1",
        ])
        XCTAssertEqual(page.identity?.session, "s1")
        XCTAssertEqual(page.items.first?.id, "100:0")
        XCTAssertTrue(page.older)
        XCTAssertFalse(page.newer)
    }

    func testBoundedChatRefusesLegacyAndOversizedRepliesWithoutFallback() async {
        let responses: [(HTTPRequest) throws -> HTTPResponse] = [
            { _ in .json(200, #"{"items":[],"start":0,"end":0,"size":0}"#) },
            { _ in .json(200, #"{"bounded":true,"byteLimit":16777216,"waiting":"wait","items":[]}"#) },
            { _ in .json(200, String(repeating: "x", count: ArgoChatPage.responseByteLimit + 1)) },
            { _ in throw HTTPError.tooLarge("response exceeds bounded limit") },
        ]
        for respond in responses {
            let t = FakeTransport(respond: respond)
            do {
                _ = try await connection(t).chat(terminal: "t1")
                XCTFail("expected update requirement")
            } catch let error as ArgoClientError {
                guard case .unsupportedServer = error else { return XCTFail("\(error)") }
            } catch { XCTFail("\(error)") }
            XCTAssertEqual(t.requests.count, 1)
            XCTAssertEqual(t.requests.first?.request.target, "/api/terminals/t1/chat?bounded=1")
            XCTAssertEqual(t.requests.first?.request.maxResponseBodyBytes, 1_048_576)
        }
    }

    func testBoundedChatWaitingAroundAndInvalidCursor() async throws {
        let t = FakeTransport { _ in .json(200, #"{"bounded":true,"byteLimit":1048576,"waiting":"native record pending","items":[]}"#) }
        let c = connection(t)
        let page = try await c.chat(terminal: "t1", cursor: .around(.init(recordOffset: 12, blockIndex: 901)), session: "s1")
        XCTAssertEqual(page.waiting, "native record pending")
        XCTAssertEqual(t.requests.first?.request.target, "/api/terminals/t1/chat?around=12%3A901&bounded=1&session=s1")
        await assertRefused { _ = try await c.chat(terminal: "t1", cursor: .after(.init(recordOffset: -1))) }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testAnswerTurnsAndValidation() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.answer) }
        let c = connection(t)
        let latest = try await c.answer(run: run)
        _ = try await c.answer(run: run, turn: 2)
        XCTAssertEqual(t.requests.map(\.request.target), ["/api/agents/\(run)/answer", "/api/agents/\(run)/answer?turn=2"])
        XCTAssertEqual(latest.turn, 3)
        XCTAssertEqual(latest.prompt?.text, "修一下")
        XCTAssertTrue(latest.final)
        await assertRefused { _ = try await c.answer(run: self.run, turn: 0) }
        await assertRefused { _ = try await c.answer(run: "unmanaged:t9") }
        XCTAssertEqual(t.requests.count, 2, "refused locally: no request")
    }

    func testSendPostsQueueOnceWithAttemptTargetAndSource() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.queued) }
        let identity = ArgoAgentIdentity(run: run, engine: "claude", session: "s1")
        let msg = ArgoOutgoingMessage(run: run, text: "继续", target: identity, attempt: "ios-attempt-0001")
        let receipt = try await connection(t).send(msg)
        XCTAssertEqual(t.requests.count, 1)
        let sent = try XCTUnwrap(t.requests.first)
        XCTAssertFalse(sent.reuse, "writes always get a fresh stream")
        XCTAssertNil(sent.timeout, "ordinary sends keep the transport default")
        XCTAssertEqual(sent.request.method, "POST")
        XCTAssertEqual(sent.request.target, "/api/agents/\(run)/queue")
        XCTAssertEqual(sent.request.header("X-Loom-Attempt"), "ios-attempt-0001")
        XCTAssertEqual(sent.request.header("Content-Type"), "application/json")
        let body = sent.request.json
        XCTAssertEqual(body["text"] as? String, "继续")
        XCTAssertEqual(body["submit"] as? Bool, true)
        XCTAssertEqual(body["when"] as? String, "auto")
        XCTAssertEqual(body["source"] as? String, "ios")
        let target = try XCTUnwrap(body["target"] as? [String: Any])
        XCTAssertEqual(target["run"] as? String, run)
        XCTAssertEqual(target["session"] as? String, "s1")
        XCTAssertEqual(target["started"] as? String, "0001-01-01T00:00:00Z")
        XCTAssertEqual(target["pid"] as? Int, 0)
        XCTAssertFalse(receipt.delivered)
        XCTAssertEqual(receipt.queued?.id, "m1")
        XCTAssertEqual(receipt.queue.hold, "Agent 正在工作")
        XCTAssertFalse(receipt.duplicate)
    }

    func testSendReportsDuplicateReplay() async throws {
        let t = FakeTransport { _ in .json(200, Fixture.delivered, headers: [("X-Loom-Duplicate", "1")]) }
        let receipt = try await connection(t).send(ArgoOutgoingMessage(run: run, text: "x", target: nil, attempt: "ios-again-001"))
        XCTAssertTrue(receipt.delivered)
        XCTAssertTrue(receipt.duplicate)
    }

    func testSendFailureKindsAreNeverRetried() async {
        let cases: [(TransportFailure, (ArgoClientError) -> Bool)] = [
            (.noReply("断开"), { $0.mayHaveBeenDelivered }),
            (.cancelled(afterWrite: true), { $0.mayHaveBeenDelivered }),
            (.notSent("写失败"), { if case .notSent = $0 { return true }; return false }),
            (.open(.timeout("超时")), { if case .notSent = $0 { return true }; return false }),
            (.open(.unauthorized("")), { if case .needsPairing = $0 { return true }; return false }),
            (.open(.fingerprintChanged), { if case .needsPairing = $0 { return true }; return false }),
        ]
        for (failure, check) in cases {
            let t = FakeTransport { _ in throw failure }
            do {
                _ = try await connection(t).send(ArgoOutgoingMessage(run: run, text: "x", target: nil))
                XCTFail("expected failure for \(failure)")
            } catch let error as ArgoClientError {
                XCTAssertTrue(check(error), "\(failure) → \(error)")
            } catch { XCTFail("\(failure) → \(error)") }
            XCTAssertEqual(t.requests.count, 1, "\(failure): sent exactly once")
        }
    }

    func testCancelledBeforeWriteIsCancellationNotFailure() async {
        let t = FakeTransport { _ in throw TransportFailure.cancelled(afterWrite: false) }
        do {
            _ = try await connection(t).send(ArgoOutgoingMessage(run: run, text: "x", target: nil))
            XCTFail("expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
    }

    func testHTTPErrorsCarryLoomdMessageAndCode() async {
        let t = FakeTransport { _ in .json(409, #"{"error":"Agent 的终端已退出，没有写入","detail":"exit 1","code":"terminal_exited"}"#) }
        do {
            _ = try await connection(t).send(ArgoOutgoingMessage(run: run, text: "x", target: nil))
            XCTFail("expected 409")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .http(status: 409, message: "Agent 的终端已退出，没有写入\nexit 1", code: "terminal_exited"))
            XCTAssertFalse(error.mayHaveBeenDelivered)
        } catch { XCTFail("\(error)") }
    }

    func testSendValidatesLocally() async {
        let t = FakeTransport()
        let c = connection(t)
        await assertRefused { _ = try await c.send(ArgoOutgoingMessage(run: self.run, text: "  \n", target: nil)) }
        await assertRefused { _ = try await c.send(ArgoOutgoingMessage(run: "unmanaged:t9", text: "x", target: nil)) }
        await assertRefused { _ = try await c.send(ArgoOutgoingMessage(run: self.run, text: "x", target: nil, attempt: "short")) }
        let other = ArgoAgentIdentity(run: "20261114-090000-00000002", engine: "claude", session: "s")
        await assertRefused { _ = try await c.send(ArgoOutgoingMessage(run: self.run, text: "x", target: other)) }
        XCTAssertEqual(t.requests.count, 0)
    }

    func testReadRetriesOnceAfter401WithNewToken() async throws {
        let first = String(repeating: "a", count: 64), second = String(repeating: "c", count: 64)
        let t = FakeTransport(tokens: [first, second]) { req in
            req.header("Authorization") == "Bearer \(first)" ? .json(401, #"{"error":"需要访问口令"}"#) : .json(200, "[]")
        }
        let list = try await connection(t).workspaces()
        XCTAssertEqual(list, [])
        XCTAssertEqual(t.tokenCalls, 2)
        XCTAssertEqual(t.requests.count, 2)
    }

    func testWriteIsNotRepeatedAfter401() async {
        let t = FakeTransport { _ in .json(401, #"{"error":"需要访问口令"}"#) }
        let c = connection(t)
        do {
            _ = try await c.send(ArgoOutgoingMessage(run: run, text: "x", target: nil))
            XCTFail("expected 401")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error.serverCode, nil)
            if case .http(let status, _, _) = error { XCTAssertEqual(status, 401) } else { XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testReplyBodyAndTerminalOnlyRefusal() async throws {
        let t = FakeTransport { _ in .json(200, #"{"id":"q2","status":"sent"}"#) }
        let c = connection(t)
        let snap = try JSONDecoder().decode(AttentionSnapshot.self, from: Data(Fixture.attention.utf8))
        let receipt = try await c.reply(snap.waiting[1], text: "A", attempt: "ios-reply-0001")
        XCTAssertEqual(receipt.status, "sent")
        let sent = try XCTUnwrap(t.requests.last?.request)
        XCTAssertEqual(sent.target, "/api/agents/\(run)/reply")
        XCTAssertEqual(sent.header("X-Loom-Attempt"), "ios-reply-0001")
        XCTAssertEqual(sent.json["terminal"] as? String, "t1")
        XCTAssertEqual(sent.json["questionID"] as? String, "q2")
        XCTAssertEqual(sent.json["agent"] as? String, "")
        XCTAssertEqual(sent.json["text"] as? String, "A")
        await assertRefused { _ = try await c.reply(snap.waiting[0], text: "y") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testCloseStopsEverything() async {
        let t = FakeTransport()
        let c = connection(t)
        await c.close()
        await c.close()
        XCTAssertEqual(t.closeCalls, 1)
        do {
            _ = try await c.workspaces()
            XCTFail("expected closed")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .closed)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 0)
    }

    func testGatewayFailuresOnReads() async {
        let t = FakeTransport()
        t.tokenError = TransportFailure.open(.banned("x"))
        do {
            _ = try await connection(t).workspaces()
            XCTFail("expected failure")
        } catch let error as ArgoClientError {
            XCTAssertEqual(error, .gateway(.banned("x")))
        } catch { XCTFail("\(error)") }
    }

    func testInvalidJSONIsReportedNotDefaulted() async {
        let t = FakeTransport { _ in .json(200, #"{"waiting":"nope"}"#) }
        do {
            _ = try await connection(t).attention()
            XCTFail("expected decode failure")
        } catch let error as ArgoClientError {
            guard case .invalidResponse = error else { return XCTFail("\(error)") }
        } catch { XCTFail("\(error)") }
    }

    func testAttemptIDsMatchLoomdFormat() {
        let a = ArgoAttempt.make(), b = ArgoAttempt.make()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(ArgoAttempt.valid(a))
        XCTAssertFalse(ArgoAttempt.valid("bad id!"))
    }

    func testTokenFailureNeverClaimsTheMessageWasWritten() async {
        let t = FakeTransport()
        t.tokenError = TransportFailure.noReply("token stream closed")
        do {
            _ = try await connection(t).send(ArgoOutgoingMessage(run: run, text: "hello", target: nil))
            XCTFail("expected failure")
        } catch let error as ArgoClientError {
            guard case .notSent = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.mayHaveBeenDelivered)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 0)
    }

    func testMalformedSuccessfulReceiptsKeepDeliveryUnknown() async {
        for body in ["not JSON", "{}"] {
            let t = FakeTransport { _ in .json(200, body) }
            let c = connection(t)
            do {
                _ = try await c.send(ArgoOutgoingMessage(run: run, text: "hello", target: nil))
                XCTFail("expected receipt failure")
            } catch let error as ArgoClientError { XCTAssertTrue(error.mayHaveBeenDelivered) }
            catch { XCTFail("\(error)") }
            do {
                _ = try await c.reply(run: run, terminal: "t1", agent: "", questionID: "q1", text: "yes")
                XCTFail("expected receipt failure")
            } catch let error as ArgoClientError { XCTAssertTrue(error.mayHaveBeenDelivered) }
            catch { XCTFail("\(error)") }
            XCTAssertEqual(t.requests.count, 2, "one request for each explicit user action")
        }
    }

    func testReplyServerFailureCanFollowPartialPTYWrite() async {
        let t = FakeTransport { _ in .json(500, #"{"error":"write failed"}"#) }
        do {
            _ = try await connection(t).reply(run: run, terminal: "t1", agent: "", questionID: "q1", text: "yes")
            XCTFail("expected server failure")
        } catch let error as ArgoClientError {
            XCTAssertTrue(error.mayHaveBeenDelivered)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testAlreadyCancelledActionDoesNotSend() async {
        let t = FakeTransport { _ in .json(200, Fixture.delivered) }
        let c = connection(t)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await c.send(ArgoOutgoingMessage(run: self.run, text: "hello", target: nil))
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 0)
        XCTAssertEqual(t.tokenCalls, 0)
    }

    func testModelRecoveryPostsOnceWithoutAttemptAndUsesScopedTimeout() async throws {
        let body = #"{"switched":true,"message":"Set model to fixture","resume":{"sent":false,"reason":"needs-you","message":"finish in terminal","retryAfterMs":1250}}"#
        let t = FakeTransport { _ in .json(200, body) }
        let receipt = try await connection(t).switchModelAndResume(run: run, model: "  fixture/model:one@host[blue]_-.  ")
        XCTAssertFalse(receipt.resume?.sent ?? true)
        XCTAssertEqual(receipt.resume?.reason, "needs-you")
        XCTAssertEqual(receipt.resume?.retryAfterMs, 1250)
        let sent = try XCTUnwrap(t.requests.first)
        XCTAssertEqual(t.requests.count, 1)
        XCTAssertEqual(sent.request.method, "POST")
        XCTAssertEqual(sent.request.target, "/api/agents/\(run)/model")
        XCTAssertEqual(sent.request.json["model"] as? String, "fixture/model:one@host[blue]_-.")
        XCTAssertNil(sent.request.header("X-Loom-Attempt"), "the model endpoint has no attempt replay contract")
        XCTAssertEqual(sent.timeout, 45)
        XCTAssertFalse(sent.reuse)
    }

    func testModelRecoveryValidationAndMalformedReceipt() async {
        let t = FakeTransport { _ in .json(200, "{}") }
        let c = connection(t)
        for invalid in ["", "has space", "中文", String(repeating: "a", count: 81), "semi;colon"] {
            await assertRefused { _ = try await c.switchModelAndResume(run: self.run, model: invalid) }
        }
        await assertRefused { _ = try await c.switchModelAndResume(run: "unmanaged:t1", model: "fixture") }
        XCTAssertEqual(t.requests.count, 0)
        do {
            _ = try await c.switchModelAndResume(run: run, model: "fixture")
            XCTFail("missing switched must not become success")
        } catch let error as ArgoClientError {
            XCTAssertTrue(error.mayHaveBeenDelivered)
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(t.requests.count, 1)
    }

    func testModelRecoveryEntryUsesLiveManagedClaudeModelError() throws {
        func card(_ update: (inout [String: Any]) -> Void) throws -> ArgoAgentCard {
            var value: [String: Any] = ["run": run, "ws": "w1", "terminal": "t1", "engine": "claude", "state": "error", "failKind": "model"]
            update(&value)
            return try JSONDecoder().decode(ArgoAgentCard.self, from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertTrue(try card { _ in }.offersModelRecovery)
        XCTAssertFalse(try card { $0["engine"] = "codex" }.offersModelRecovery)
        XCTAssertFalse(try card { $0["failKind"] = "policy" }.offersModelRecovery)
        XCTAssertFalse(try card { $0["state"] = "working" }.offersModelRecovery)
        XCTAssertFalse(try card { $0["run"] = "unmanaged:t1" }.offersModelRecovery)
        XCTAssertFalse(try card { $0["terminal"] = "" }.offersModelRecovery)
        XCTAssertFalse(try card { $0["exitCode"] = 1 }.offersModelRecovery)
        XCTAssertFalse(try card { $0["endReason"] = "exit" }.offersModelRecovery)
    }

    private func assertRefused(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected local refusal", file: file, line: line)
        } catch let error as ArgoClientError {
            guard case .refusedLocally = error else { return XCTFail("\(error)", file: file, line: line) }
        } catch { XCTFail("\(error)", file: file, line: line) }
    }
}
