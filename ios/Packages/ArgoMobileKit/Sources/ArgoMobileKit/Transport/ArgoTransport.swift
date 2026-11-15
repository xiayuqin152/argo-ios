import Foundation

/// Carries loomd HTTP requests to one dev machine. `GatewayHTTPTransport`
/// is the real one (pinned TLS gateway streams); tests supply their own.
public protocol ArgoHTTPTransport: Sendable {
    /// loomd's HTTP token through the gateway's `token` op (64 hex digits).
    func loomdToken() async throws -> String
    /// One request, one reply. `reuse` lets an idle stream carry it and keeps
    /// the stream for the next request; only idempotent requests ask for it.
    /// `timeout` overrides the finite reply wait for this request only; nil
    /// uses the transport's normal default.
    /// Failures are `TransportFailure`, or `HTTPError.invalidRequest` before
    /// anything was opened.
    func send(_ request: HTTPRequest, reuse: Bool, timeout: TimeInterval?) async throws -> HTTPResponse
    /// Ends every stream; requests in flight fail with `.cancelled`.
    func close() async
}

/// Where a request failed. What a failed message send means for the user
/// depends on it: before the request was handed to the stream nothing can
/// have reached loomd, after it the message may have arrived.
public enum TransportFailure: Error, Equatable, Sendable {
    /// No stream: TLS, pinning, the gateway's reply line.
    case open(GatewayError)
    /// The request was not completely handed to the stream.
    case notSent(ArgoClientError.Reason)
    /// The request was handed over; the reply never arrived complete.
    case noReply(ArgoClientError.Reason)
    /// System diagnostics from a transport or fixture remain verbatim.
    public static func notSent(_ detail: String) -> Self { .notSent(.detail(detail)) }
    public static func noReply(_ detail: String) -> Self { .noReply(.detail(detail)) }

    /// The caller cancelled, or the transport was closed. `afterWrite`: the
    /// request bytes had been handed to the stream already.
    case cancelled(afterWrite: Bool)
    /// The transport was closed before this request started.
    case closed
}
