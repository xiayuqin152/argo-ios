import Foundation
@testable import ArgoMobileKit

/// Scripted transport: records every request and answers from `respond`.
final class FakeTransport: ArgoHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(request: HTTPRequest, reuse: Bool, timeout: TimeInterval?)] = []
    private var _tokenCalls = 0
    private var _closed = 0
    var tokens: [String]
    var tokenError: Error?
    var respond: (HTTPRequest) throws -> HTTPResponse

    init(tokens: [String] = [String(repeating: "a", count: 64)],
         respond: @escaping (HTTPRequest) throws -> HTTPResponse = { _ in .json(200, "{}") }) {
        self.tokens = tokens
        self.respond = respond
    }

    var requests: [(request: HTTPRequest, reuse: Bool, timeout: TimeInterval?)] { lock.lock(); defer { lock.unlock() }; return _requests }
    var tokenCalls: Int { lock.lock(); defer { lock.unlock() }; return _tokenCalls }
    var closeCalls: Int { lock.lock(); defer { lock.unlock() }; return _closed }

    private func locked<R>(_ body: () -> R) -> R { lock.lock(); defer { lock.unlock() }; return body() }

    func loomdToken() async throws -> String {
        let i = locked { () -> Int in _tokenCalls += 1; return min(_tokenCalls, tokens.count) - 1 }
        if let tokenError { throw tokenError }
        return tokens[i]
    }

    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse {
        locked { _requests.append((request, reuse, timeout)) }
        _ = try request.encoded(keepAlive: reuse)
        return try respond(request)
    }

    func close() async { locked { _closed += 1 } }
}

extension HTTPResponse {
    static func queuePreview(_ status: Int, _ body: String, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        var object = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        object["bounded"] = true; object["byteLimit"] = 8_388_608
        return HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers,
                            body: try! JSONSerialization.data(withJSONObject: object), reusable: true)
    }
    static func json(_ status: Int, _ body: String, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: Data(body.utf8), reusable: true)
    }
}

extension HTTPRequest {
    func header(_ name: String) -> String? { headers.first { $0.name.lowercased() == name.lowercased() }?.value }
    var json: [String: Any] { (body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
}

enum Fixture {
    static let fingerprint = Data((0..<32).map { UInt8($0) })
    static let secret = Base64URL.encode(Data(repeating: 7, count: 16))
    static func code(host: String = "10.0.0.5", port: Int = 6779) -> String {
        "argo1:\(host):\(port):\(Base64URL.encode(fingerprint)):\(secret)"
    }
    static let token = String(repeating: "b", count: 43)

    static func host() -> LoomHost {
        LoomHost(name: "dev", address: "10.0.0.5", gatewayPort: 6779, fingerprint: Base64URL.encode(fingerprint), deviceID: "dev123")
    }

    // Shapes follow loomd's json tags (see ArgoModels.swift for the Go structs).
    static let health = #"{"host":"devbox","vscode":true,"installations":{},"capabilities":["x"],"warnings":[],"api":1,"version":"1.0.12","commit":"abc","build":42,"uptime":10,"rg":true,"ptyd":true,"user":"me","components":{}}"#

    static let attention = #"""
    {"waiting":[{"unread":true,"questionID":"q1","run":"unmanaged:t9","terminal":"t9","ws":"w1","workspace":"Work","title":"claude","agent":"","name":"","kind":"question","question":"继续吗？","options":null,"optionNotes":null,"terminalOnly":"手动启动的 Agent，请在终端里回答"},
                {"unread":false,"questionID":"q2","run":"20261115-101010-abcdef01","terminal":"t1","ws":"w1","workspace":"Work","title":"Fix bug","agent":"","name":"","kind":"question","question":"选哪个？","options":["A","B"],"at":"2026-11-15T10:10:10.123456789+08:00","optionNotes":["first","second"]}],
     "errors":0,
     "agents":[{"run":"20261115-101010-abcdef01","terminal":"t1","ws":"w1","workspace":"Work","title":"Fix bug","label":"Claude Code","profile":"claude","state":"waiting","interrupted":false,"stateText":"等你回答","stateStartedAt":"2026-11-15T10:10:10Z","notifyNewWaiting":false,"errorAt":"0001-01-01T00:00:00Z","unread":true}],
     "unreadable":[],"working":1}
    """#

    static let cards = #"""
    [{"run":"20261115-101010-abcdef01","ws":"w1","terminal":"t1","profile":"claude","engine":"claude","cli":"Claude Code","leader":false,"status":"waiting","title":"Fix bug","activity":"Edit main.go","tone":"warn","ask":{"unread":true,"questionID":"q2","run":"20261115-101010-abcdef01","agent":"","name":"","kind":"question","text":"选哪个？","options":["A","B"],"at":"2026-11-15T10:10:10Z"},"waitingIDs":["q2"],"usage":{},"members":null,"tasks":3,"done":1,"created":"2026-11-15T10:00:00Z","updated":"2026-11-15T10:10:10Z","queued":2,"plan":{"items":[{"text":"读代码","status":"done"},{"text":"改","status":"in_progress"}],"done":1,"total":2,"updated":"2026-11-15T10:05:00Z"},"continue":{},"state":"waiting","interrupted":false,"stateText":"等你回答","stateStartedAt":"2026-11-15T10:10:10Z","unread":true,"attention":5},
     {"run":"20261114-090000-00000002","ws":"w2","terminal":"t2","profile":"codex","engine":"codex","cli":"Codex","leader":false,"status":"done","title":"","activity":"","tone":"","ask":null,"waitingIDs":null,"usage":{},"members":[],"tasks":0,"done":0,"created":"2026-11-14T09:00:00Z","updated":"2026-11-14T09:30:00Z","queued":0,"continue":{},"state":"done","interrupted":false,"stateText":"完成","stateStartedAt":"2026-11-14T09:30:00Z","unread":false,"attention":0}]
    """#

    static let team = #"""
    {"process":null,"userTurns":null,"run":"20261115-101010-abcdef01","terminal":"t1","ws":"w1","cwd":"/src","id":"lead","title":"Fix bug","engine":"claude","profile":"claude","cli":"Claude Code","leader":false,
     "status":"active","started":"2026-11-15T10:00:00Z","ended":"0001-01-01T00:00:00Z","seen":"0001-01-01T00:00:00Z","usage":{},"now":"2026-11-15T10:11:00Z","tone":"",
     "steps":[{"at":"2026-11-15T10:10:00Z","text":"Edit main.go","count":2,"mark":"edit"}],"members":[],"tasks":[{"id":"1","title":"Write tests","owner":"lead","status":"active","description":"","blockedBy":[]}],"done":0,
     "asks":[{"unread":false,"questionID":"p1","run":"20261115-101010-abcdef01","agent":"","name":"","kind":"permission","text":"要执行：rm -rf build","options":[],"risk":"destructive","terminalOnly":"权限请求只能在终端里处理","at":"2026-11-15T10:10:30Z"}],
     "waitingIDs":["p1"],"effects":[],"warnings":[],"revision":3,"updated":"2026-11-15T10:10:30Z","created":"2026-11-15T10:00:00Z","continue":{},
     "plan":{"items":[{"text":"a","status":"pending"}],"done":0,"total":1,"updated":"2026-11-15T10:05:00Z"},
     "state":"working","interrupted":false,"stateText":"工作中","stateStartedAt":"2026-11-15T10:10:00Z","unread":false,"attention":1}
    """#

    static func chat(session: String = "s1", start: Int64 = 100, end: Int64 = 400, size: Int64 = 400,
                     startBlock: Int = 0, endBlock: Int = 0, items: String) -> String {
        #"{"bounded":true,"byteLimit":1048576,"identity":{"run":"20261115-101010-abcdef01","engine":"claude","pid":0,"start":"","started":"0001-01-01T00:00:00Z","session":"\#(session)"},"items":[\#(items)],"start":"\#(start):\#(startBlock)","end":"\#(end):\#(endBlock)","size":\#(size),"older":\#(start > 0 || startBlock > 0),"newer":\#(end < size),"skipped":0}"#
    }

    static func item(_ id: String, offset: Int64, block: Int = 0, role: String = "assistant", text: String = "hi",
                     type: String = "message", extra: [String: Any] = [:]) -> String {
        var fields: [String: Any] = ["id": id, "offset": offset, "cursor": "\(offset):\(block)", "type": type,
                                     "role": role, "text": text, "at": "2026-11-15T10:00:00Z"]
        fields.merge(extra) { _, new in new }
        return String(decoding: try! JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    static let answer = ###"{"prompt":{"nativeId":"u3","at":"2026-11-15T10:00:00Z","text":"修一下"},"process":[{"type":"steps","at":"2026-11-15T10:00:01Z","steps":[{"Time":"2026-11-15T10:00:01Z","Role":"step","Text":"Read a.go","NativeID":"x"}]}],"text":"## 好了","final":true,"turn":3,"turns":3}"###

    static let delivered = #"{"bounded":true,"byteLimit":8388608,"delivered":true,"queue":{"run":"20261115-101010-abcdef01","hold":"","items":[],"later":[]}}"#
    static let queued = #"{"bounded":true,"byteLimit":8388608,"delivered":false,"item":{"id":"m1","text":"继续","submit":true,"source":"ios","created":"2026-11-15T10:12:00Z"},"queue":{"run":"20261115-101010-abcdef01","state":"working","hold":"Agent 正在工作","items":[{"id":"m1","text":"继续","submit":true,"source":"ios","created":"2026-11-15T10:12:00Z"}],"later":[]}}"#
}
