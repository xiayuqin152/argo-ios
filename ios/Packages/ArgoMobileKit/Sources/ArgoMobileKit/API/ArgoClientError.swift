import Foundation

/// Every failure the core reports. Nothing is swallowed or turned into a
/// default. The UI localizes the typed reason and decides from the case
/// what the user can do next; server details remain verbatim.
public enum ArgoClientError: Error, LocalizedError, Equatable, Sendable {
    /// This connection was closed (backgrounded, host switched).
    case closed
    /// Only pairing again helps: no device token, the gateway refused it, or
    /// the gateway's certificate is not the pinned one.
    case needsPairing(Reason)
    /// The dev machine runs an Argo too old for this app (LoomdAPI.minimum);
    /// the Mac app upgrades it.
    case unsupportedServer(Reason)
    /// The gateway could not be reached or refused the stream (timeout,
    /// network, banned address…). Reconnecting may help.
    case gateway(GatewayError)
    /// loomd answered with an error status: its verbatim summary (and detail),
    /// and its machine code when it sent one.
    case http(status: Int, message: String, code: String?)
    /// A write failed before its request was handed to the stream:
    /// it did not reach the dev machine and may be sent again.
    case notSent(Reason)
    /// A write was handed to the stream but its receipt never arrived: it may
    /// have reached the Agent. Message/reply endpoints cache their attempt id
    /// for 10 minutes. Interrupt has no attempt cache and must not be replayed;
    /// read current state before a new explicit stop action.
    case deliveryUnknown(Reason)
    /// The reply was not the HTTP or JSON this client understands.
    case invalidResponse(Reason)
    /// Refused here before any request (blank text, a question that only the
    /// terminal can answer, a run without a managed queue…).
    case refusedLocally(Reason)

    /// Local messages carry a resource key and format arguments. Gateway failures
    /// retain their type even when a request never reached the stream.
    public enum Reason: Equatable, Sendable {
        case message(String, arguments: [String] = [])
        case gateway(GatewayError)
        case detail(String)

        public var description: String {
            switch self {
            case .message(let key, let arguments):
                return String(format: key, arguments: arguments.map { $0 as CVarArg })
            case .gateway(let error): return error.localizedDescription
            case .detail(let text): return text
            }
        }
    }

    public var errorDescription: String? {
        switch self {
        case .closed: return "The connection is closed."
        case .needsPairing(let reason), .unsupportedServer(let reason),
             .invalidResponse(let reason), .refusedLocally(let reason): return reason.description
        case .gateway(let error): return error.localizedDescription
        case .http(let status, let message, _):
            let detail = message.isEmpty ? "The host returned an error (HTTP \(status))." : message
            return status >= 500 ? "The host failed to process the request; it may have arrived: \(detail) Refresh the conversation to check." : detail
        case .notSent(let reason): return "Not sent: \(reason.description)"
        case .deliveryUnknown(let reason):
            return "May have arrived: \(reason.description) Refresh the conversation before deciding whether to resend."
        }
    }

    /// Whether a failed send may still have been delivered. Only
    /// `deliveryUnknown`, or a server failure that could follow a partial
    /// PTY write. Client error statuses such as 401 and 409 refuse delivery.
    public var mayHaveBeenDelivered: Bool {
        if case .deliveryUnknown = self { return true }
        if case .http(let status, _, _) = self { return status >= 500 }
        return false
    }

    /// loomd's machine code (`code` of err_proto), when it sent one.
    public var serverCode: String? {
        if case .http(_, _, let code) = self { return code }
        return nil
    }
}
