import ArgoMobileKit
import Foundation

nonisolated enum L10n {
    static func text(_ key: String, bundle: Bundle = .main) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    /// Translate client summaries at presentation time. Remote error bodies and
    /// system diagnostics carried as `.detail` are never used as resource keys.
    static func error(_ error: Error, bundle: Bundle = .main) -> String {
        switch error {
        case let client as ArgoClientError:
            switch client {
            case .closed: return text("The connection is closed.", bundle: bundle)
            case .needsPairing(let reason), .unsupportedServer(let reason),
                 .invalidResponse(let reason), .refusedLocally(let reason):
                return describe(reason, bundle: bundle)
            case .gateway(let error): return gateway(error, bundle: bundle)
            case .http(let status, let message, _):
                let detail = message.isEmpty
                    ? format("The host returned an error (HTTP %@).", [String(status)], bundle: bundle)
                    : message
                return status >= 500
                    ? format("The host could not complete the request. It may have arrived: %@\nRefresh the conversation to check.", [detail], bundle: bundle)
                    : detail
            case .notSent(let reason):
                return format("Not sent: %@", [describe(reason, bundle: bundle)], bundle: bundle)
            case .deliveryUnknown(let reason):
                return format("May have arrived: %@\nRefresh the conversation before deciding whether to resend.", [describe(reason, bundle: bundle)], bundle: bundle)
            }
        case let error as GatewayError:
            return gateway(error, bundle: bundle)
        case let error as NSError where error.domain == NSOSStatusErrorDomain:
            return format("Could not delete this device's saved credential (OSStatus %@). Try again.", [String(error.code)], bundle: bundle)
        case is CancellationError:
            return text("The operation was cancelled.", bundle: bundle)
        default:
            return error.localizedDescription
        }
    }

    /// File transfer has no queue receipt. HTTP errors and a lost upload
    /// response must never be presented as an Agent delivery acknowledgement.
    static func fileError(_ error: Error, bundle: Bundle = .main) -> String {
        if let client = error as? ArgoClientError {
            switch client {
            case .http(let status, let message, _):
                return format("File request failed (HTTP %@): %@", [String(status), message], bundle: bundle)
            case .deliveryUnknown(let reason):
                return format("Upload status unknown. The message was not sent: %@", [describe(reason, bundle: bundle)], bundle: bundle)
            default: break
            }
        }
        return self.error(error, bundle: bundle)
    }

    private static func describe(_ reason: ArgoClientError.Reason, bundle: Bundle) -> String {
        switch reason {
        case .message(let key, let arguments): return format(key, arguments, bundle: bundle)
        case .gateway(let error): return gateway(error, bundle: bundle)
        case .detail(let detail): return detail
        }
    }

    private static func format(_ key: String, _ arguments: [String], bundle: Bundle) -> String {
        String(format: text(key, bundle: bundle), arguments: arguments.map { $0 as CVarArg })
    }

    private static func gateway(_ error: GatewayError, bundle: Bundle) -> String {
        let key: String
        let remoteDetail: String
        switch error {
        case .fingerprintChanged:
            return text("The host's certificate changed. Argo stopped connecting because the host may have been reinstalled or the connection intercepted. Pair again.", bundle: bundle)
        case .unauthorized(let detail):
            key = "The host no longer accepts this device's credential. It may have been revoked with argo devices revoke. Run argo pair on the host and pair again."
            remoteDetail = detail
        case .pairingRejected(let detail):
            key = "Pairing failed. The code may be expired, already used, or incorrect. Run argo pair on the host to get a new code."
            remoteDetail = detail
        case .banned(let detail):
            key = "The gateway temporarily blocked this device's address after too many failed attempts. Try again in 10 minutes."
            remoteDetail = detail
        case .refused(let detail):
            key = "The host refused the connection."
            remoteDetail = detail
        case .unreachable(let detail):
            key = "The host could not be reached."
            remoteDetail = detail
        case .rejected(let detail):
            key = "The gateway refused the request."
            remoteDetail = detail
        case .strandsTerminals(let detail, _, _):
            return detail
        // These cases describe local connection/protocol failures, rather than
        // a server response body. Show the localized recovery guidance.
        case .network, .handshakeClosed:
            return text("Could not connect to the host gateway. Check the network and try again.", bundle: bundle)
        case .timeout:
            return text("The host gateway did not respond in time. Try again.", bundle: bundle)
        case .protocolError:
            return text("The gateway returned an invalid response. Check that Argo on the host is up to date.", bundle: bundle)
        case .localPort:
            return text("Could not open a local port for the gateway connection. Try again.", bundle: bundle)
        }
        let summary = text(key, bundle: bundle)
        return remoteDetail.isEmpty ? summary : summary + "\n" + remoteDetail
    }
}
