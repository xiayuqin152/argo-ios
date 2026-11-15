import Foundation

/// Whether the device token can be read without any keychain UI.
public enum TokenAccess: Equatable, Sendable {
    case available
    /// No (valid) token is stored for the host.
    case missing
    /// The keychain would have to ask the user (locked, authorization) or failed.
    case unavailable(reason: String)
}

/// What launch does with one host.
public enum HostLaunchOutcome: Equatable, Sendable {
    /// Start the connection pass in the background.
    case connect
    /// Not paired, or the credential is gone: only repairing the pairing helps.
    case needsPairing(reason: String)
    /// Not tried: the keychain would have to ask the user. The click on the host's
    /// connect action makes the one interactive attempt.
    case deferred(reason: String)
}

public enum HostLaunch {
    public static let missingTokenReason = "钥匙串里没有这台远程的设备凭据。请在远程上执行 \(RemoteHint.command("pair"))，然后在 Argo 里重新配对。"

    /// `token` is only consulted for a paired remote host, so the keychain stays
    /// untouched for the local host and for hosts that cannot connect anyway.
    public static func outcome(for host: LoomHost, token: () -> TokenAccess) -> HostLaunchOutcome {
        if host.isLocal { return .connect }
        do { try host.validate() } catch {
            return .needsPairing(reason: error.localizedDescription)
        }
        switch token() {
        case .available:
            return .connect
        case .missing:
            return .needsPairing(reason: missingTokenReason)
        case .unavailable(let reason):
            return .deferred(reason: "钥匙串暂时不能免交互读取（\(reason)）。打开这台远程时会请求解锁。")
        }
    }
}
