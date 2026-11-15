import Foundation

// HTTP/1.1 spoken directly on a gateway `http` stream (api.md v1.14: raw
// bytes to/from loomd's 127.0.0.1 listener). The Mac reaches the same bytes
// through a loopback listener and URLSession; the phone has no listener, so it
// writes the request and parses the reply itself.

/// One request to loomd. Only what the API needs: a method, an origin-form
/// target, JSON bodies and the bearer token. Every field is checked before a
/// byte is written, so a value can never end a header line early.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    /// Origin-form target: `/api/agents/<run>?turn=2`.
    public var target: String
    public var headers: [(name: String, value: String)]
    public var body: Data?
    /// Local response bound; never encoded as an HTTP header.
    public var maxResponseBodyBytes: Int

    public init(method: String, target: String, headers: [(name: String, value: String)] = [], body: Data? = nil,
                maxResponseBodyBytes: Int = HTTPResponseParser.defaultMaxBody) {
        self.method = method
        self.target = target
        self.headers = headers
        self.body = body
        self.maxResponseBodyBytes = maxResponseBodyBytes
    }

    public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
        a.method == b.method && a.target == b.target && a.body == b.body && a.maxResponseBodyBytes == b.maxResponseBodyBytes
            && a.headers.map(\.name) == b.headers.map(\.name) && a.headers.map(\.value) == b.headers.map(\.value)
    }

    /// GET and HEAD change nothing on loomd; only they may be repeated on a
    /// fresh stream after a reused one turned out closed.
    public var idempotent: Bool { method == "GET" || method == "HEAD" }

    /// loomd refuses any Host that does not name loopback (internal/auth
    /// LocalHost); the gateway dials 127.0.0.1 on the dev machine, so this is
    /// the name the request really reaches.
    public static let loopbackHost = "127.0.0.1:3430"

    /// The bytes on the wire. `keepAlive` false asks loomd to close after the
    /// reply.
    public func encoded(keepAlive: Bool) throws -> Data {
        guard Self.isToken(method) else { throw HTTPError.invalidRequest("请求方法不合法") }
        // A valid 4096-byte attachment path can expand to 12 KiB in a query.
        guard target.hasPrefix("/"), target.utf8.count <= 16 * 1024,
              target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw HTTPError.invalidRequest("请求路径不合法")
        }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(Self.loopbackHost)\r\n"
        for (name, value) in headers {
            guard Self.isToken(name), !Self.managed.contains(name.lowercased()) else {
                throw HTTPError.invalidRequest("请求头名「\(name.prefix(40))」不合法")
            }
            guard value.unicodeScalars.allSatisfy({ $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) }) else {
                throw HTTPError.invalidRequest("请求头「\(name)」的值含控制字符")
            }
            head += "\(name): \(value)\r\n"
        }
        if let body {
            head += "Content-Length: \(body.count)\r\n"
        } else if !idempotent {
            head += "Content-Length: 0\r\n"
        }
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }

    /// Headers the encoder writes itself.
    static let managed: Set<String> = ["host", "content-length", "connection", "transfer-encoding"]

    /// RFC 9110 token characters.
    static func isToken(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy { c in
            (c.value >= 0x30 && c.value <= 0x39) || (c.value >= 0x41 && c.value <= 0x5A) || (c.value >= 0x61 && c.value <= 0x7A)
                || "!#$%&'*+-.^_`|~".unicodeScalars.contains(c)
        }
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// The reply left the stream ready for another request (HTTP/1.1, no
    /// `Connection: close`, and a body whose end was framed).
    public var reusable: Bool

    public init(status: Int, headers: [(name: String, value: String)], body: Data, reusable: Bool) {
        self.status = status
        self.headers = headers
        self.body = body
        self.reusable = reusable
    }

    public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
        a.status == b.status && a.body == b.body && a.reusable == b.reusable
            && a.headers.map(\.name) == b.headers.map(\.name) && a.headers.map(\.value) == b.headers.map(\.value)
    }

    /// The first header with this name, case-insensitively.
    public func header(_ name: String) -> String? {
        let key = name.lowercased()
        return headers.first { $0.name.lowercased() == key }?.value
    }
}

public enum HTTPError: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String)
    case malformed(String)
    case tooLarge(String)
    /// The stream ended before the reply was complete.
    case truncated

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let s), .malformed(let s), .tooLarge(let s): return s
        case .truncated: return "远程在回复结束前关闭了连接"
        }
    }
}

/// Reads one HTTP/1.1 reply from bytes as they arrive: Content-Length,
/// chunked, or until the stream ends. Interim 1xx replies are skipped. Sizes
/// are bounded, so a confused peer cannot make the phone buffer without end.
public struct HTTPResponseParser: Sendable {
    public static let maxHead = 64 * 1024
    /// General API response bound. Bounded chat requests override this with
    /// ArgoChatPage.responseByteLimit; legacy unbounded chat is not requested.
    public static let defaultMaxBody = 16 * 1024 * 1024

    private enum Framing { case length(Int), chunked, untilClose, none }
    private enum State { case head, body(Framing), done }

    private let maxBody: Int
    private let headRequest: Bool
    private var buffer = Data()
    private var state = State.head
    private var status = 0
    private var headers: [(name: String, value: String)] = []
    private var body = Data()
    private var keepAlive = true
    /// Chunked: bytes still due in the current chunk; nil while reading a size line.
    private var chunkLeft: Int?
    private var trailers = false
    /// Any byte of a reply arrived (a reused stream that ends without one was
    /// closed while idle).
    public private(set) var receivedAny = false

    public init(maxBody: Int = HTTPResponseParser.defaultMaxBody, headRequest: Bool = false) {
        self.maxBody = maxBody
        self.headRequest = headRequest
    }

    /// Feeds bytes; returns the reply once it is complete. Bytes after it are
    /// a protocol error (loomd never pipelines).
    public mutating func append(_ data: Data) throws -> HTTPResponse? {
        if !data.isEmpty { receivedAny = true }
        if case .done = state {
            if !data.isEmpty { throw HTTPError.malformed("远程在回复之后又发来了数据") }
            return nil
        }
        buffer.append(data)
        return try advance()
    }

    /// The stream ended: completes a reply framed by the end of the stream,
    /// anything else was cut short.
    public mutating func finish() throws -> HTTPResponse {
        if case .body(.untilClose) = state {
            body.append(buffer)
            buffer.removeAll()
            guard body.count <= maxBody else { throw HTTPError.tooLarge("远程的回复超过 \(maxBody / 1024 / 1024) MiB") }
            state = .done
            return HTTPResponse(status: status, headers: headers, body: body, reusable: false)
        }
        throw HTTPError.truncated
    }

    private mutating func advance() throws -> HTTPResponse? {
        while true {
            switch state {
            case .done:
                return nil
            case .head:
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if buffer.count > Self.maxHead { throw HTTPError.tooLarge("远程的回复头过长") }
                    return nil
                }
                let head = buffer[buffer.startIndex..<end.lowerBound]
                buffer = Data(buffer[end.upperBound...])
                guard head.count <= Self.maxHead else { throw HTTPError.tooLarge("远程的回复头过长") }
                try parseHead(Data(head))
                if (100..<200).contains(status) {
                    // 100 Continue and friends: the real reply follows.
                    headers = []
                    continue
                }
                state = .body(try framing())
            case .body(let framing):
                switch framing {
                case .none:
                    if !buffer.isEmpty { throw HTTPError.malformed("远程在回复之后又发来了数据") }
                    return complete()
                case .length(let n):
                    guard buffer.count >= n else { return nil }
                    body = Data(buffer.prefix(n))
                    if buffer.count > n { throw HTTPError.malformed("远程在回复之后又发来了数据") }
                    buffer.removeAll()
                    return complete()
                case .untilClose:
                    body.append(buffer)
                    buffer.removeAll()
                    guard body.count <= maxBody else { throw HTTPError.tooLarge("远程的回复超过 \(maxBody / 1024 / 1024) MiB") }
                    return nil
                case .chunked:
                    guard try readChunks() else { return nil }
                    if !buffer.isEmpty { throw HTTPError.malformed("远程在回复之后又发来了数据") }
                    return complete()
                }
            }
        }
    }

    private mutating func complete() -> HTTPResponse {
        state = .done
        let reusable: Bool
        switch framingKind {
        case .untilClose: reusable = false
        default: reusable = keepAlive
        }
        return HTTPResponse(status: status, headers: headers, body: body, reusable: reusable)
    }

    private var framingKind: Framing {
        if case .body(let f) = state { return f }
        return .none
    }

    private mutating func parseHead(_ head: Data) throws {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            throw HTTPError.malformed("远程的回复头不是文本")
        }
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0",
              parts[1].count == 3, let code = Int(parts[1]), (100...599).contains(code) else {
            throw HTTPError.malformed("远程的回复不是 HTTP（状态行「\(statusLine.prefix(60))」）")
        }
        status = code
        keepAlive = parts[0] == "HTTP/1.1"
        headers = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed("远程的回复头格式不对") }
            let name = String(line[..<colon])
            guard HTTPRequest.isToken(name) else { throw HTTPError.malformed("远程的回复头名不合法") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        if let connection = header("connection")?.lowercased() {
            let tokens = connection.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.contains("close") { keepAlive = false }
            if tokens.contains("keep-alive") && parts[0] == "HTTP/1.0" { keepAlive = true }
        }
    }

    private func header(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name }?.value
    }

    private func framing() throws -> Framing {
        if headRequest || status == 204 || status == 304 { return .none }
        if let te = header("transfer-encoding")?.lowercased() {
            guard te.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) == "chunked" else {
                throw HTTPError.malformed("远程用了不支持的传输编码「\(te.prefix(40))」")
            }
            return .chunked
        }
        if let cl = header("content-length") {
            guard !cl.isEmpty, cl.count <= 12, cl.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(cl) else {
                throw HTTPError.malformed("远程的 Content-Length 不合法")
            }
            guard n <= maxBody else { throw HTTPError.tooLarge("远程的回复超过 \(maxBody / 1024 / 1024) MiB") }
            return .length(n)
        }
        return .untilClose
    }

    /// true once the last chunk and its trailers were read.
    private mutating func readChunks() throws -> Bool {
        let crlf = Data("\r\n".utf8)
        while true {
            if trailers {
                guard let end = buffer.range(of: crlf) else {
                    if buffer.count > Self.maxHead { throw HTTPError.tooLarge("远程的分块尾部过长") }
                    return false
                }
                let empty = end.lowerBound == buffer.startIndex
                buffer = Data(buffer[end.upperBound...])
                if empty { return true }
                continue
            }
            if let left = chunkLeft {
                guard buffer.count >= left + 2 else { return false }
                body.append(buffer.prefix(left))
                guard buffer[buffer.startIndex + left] == 0x0D, buffer[buffer.startIndex + left + 1] == 0x0A else {
                    throw HTTPError.malformed("远程的分块数据格式不对")
                }
                buffer = Data(buffer.dropFirst(left + 2))
                chunkLeft = nil
                continue
            }
            guard let end = buffer.range(of: crlf) else {
                if buffer.count > 1024 { throw HTTPError.malformed("远程的分块长度行过长") }
                return false
            }
            let line = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end.upperBound...])
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, let size = Int(sizeText, radix: 16), size >= 0 else {
                throw HTTPError.malformed("远程的分块长度不合法")
            }
            guard body.count + size <= maxBody else { throw HTTPError.tooLarge("远程的回复超过 \(maxBody / 1024 / 1024) MiB") }
            if size == 0 { trailers = true } else { chunkLeft = size }
        }
    }
}
