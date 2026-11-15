import Foundation

/// UD-08: this Mac's own record of why and for how long its control stream
/// to one dev machine was down. The next hello carries it as
/// `lastDisconnect`; it is repeated on every hello until the gateway
/// answered a ping sent right behind one (it handles lines in order, so the
/// pong proves the record was read). loomd keeps the last 20 for
/// 设置 › 网络 › 网关.
///
/// One per host (HostSessionCore), shared by the host's replacement
/// tunnels; used only on the transport queue.
public final class DisconnectTracker: @unchecked Sendable {
    /// What ended the control stream on this side.
    public enum Cause: String, Sendable {
        case heartbeatTimeout = "heartbeat_timeout"
        case probeTimeout = "probe_timeout"
        case serverClosed = "server_closed"
        case networkError = "network_error"
        case protocolError = "protocol_error"
        /// 「重新连接」 by the user.
        case manual
        /// Argo stopped the tunnel: disconnect, window rebuild, quit.
        case localStop = "local_stop"

        /// A timeout means the link had been dead since its last message.
        var isTimeout: Bool { self == .heartbeatTimeout || self == .probeTimeout }
    }

    /// One reading of the clocks: `wall` counts sleep (ContinuousClock),
    /// `awake` does not (uptime); `unixMs` names the drop for the gateway.
    public struct Instant: Equatable, Sendable {
        public var wall: TimeInterval
        public var awake: TimeInterval
        public var unixMs: Int64
        public init(wall: TimeInterval, awake: TimeInterval, unixMs: Int64) {
            self.wall = wall; self.awake = awake; self.unixMs = unixMs
        }
        func slept(since earlier: Instant) -> TimeInterval {
            max(0, (wall - earlier.wall) - (awake - earlier.awake))
        }
    }

    /// The record as the hello carries it.
    public struct Report: Equatable, Sendable {
        public var at: Int64
        public var offlineMs: Int64
        public var sleptMs: Int64
        public var reason: String
        public var cause: String
        public var detail: String

        public var json: [String: Any] {
            ["at": at, "offlineMs": offlineMs, "sleptMs": sleptMs, "reason": reason, "cause": cause, "detail": detail]
        }
    }

    /// More sleep than this between the last message and the drop makes the
    /// drop a 「睡眠」 one.
    public static let sleepCause: TimeInterval = 5
    /// A network path change this soon after the drop still caused it (the
    /// connection error can arrive before the path update).
    public static let networkGrace: TimeInterval = 5

    private struct Drop {
        var cause: Cause
        var detail: String
        var at: Instant
        var lastAlive: Instant
        var pathChange: Instant?
    }

    private var up = false
    private var lastAlive: Instant?
    private var pathChange: Instant?
    private var pending: Drop?

    public init() {}

    /// The gateway said hello on a new control stream.
    public func connected(_ now: Instant) {
        up = true
        alive(now)
    }

    /// Any line arrived from the gateway.
    public func alive(_ now: Instant) {
        lastAlive = now
        pathChange = nil
    }

    /// The network path changed (any NWPath update).
    public func pathChanged(_ now: Instant) {
        if pending != nil {
            if pending!.pathChange == nil { pending!.pathChange = now }
        } else {
            pathChange = now
        }
    }

    /// The control stream ended. Only a stream the gateway said hello on
    /// counts, and only the first drop of an outage: the failed attempts
    /// after it are the same outage.
    public func dropped(_ cause: Cause, detail: String, _ now: Instant) {
        guard up else { return }
        up = false
        guard pending == nil else { return }
        pending = Drop(cause: cause, detail: String(detail.prefix(200)), at: now,
                       lastAlive: lastAlive ?? now, pathChange: pathChange)
    }

    /// The record for the hello sent at now; nil when nothing is owed.
    public func report(_ now: Instant) -> Report? {
        guard let d = pending else { return nil }
        let sleptFirst = d.at.slept(since: d.lastAlive) > Self.sleepCause
        let network = d.pathChange.map { $0.wall <= d.at.wall + Self.networkGrace } ?? false
        let start = sleptFirst || d.cause.isTimeout ? d.lastAlive : d.at
        let reason = sleptFirst ? "sleep" : network ? "network" : d.cause.rawValue
        return Report(at: d.at.unixMs, offlineMs: Int64(max(0, now.wall - start.wall) * 1000),
                      sleptMs: Int64(now.slept(since: start) * 1000), reason: reason,
                      cause: d.cause.rawValue, detail: d.detail)
    }

    /// The gateway read the hello that carried the record named at.
    public func delivered(_ at: Int64) {
        if pending?.at.unixMs == at { pending = nil }
    }
}
