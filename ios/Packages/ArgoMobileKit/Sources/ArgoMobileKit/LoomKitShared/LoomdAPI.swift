import Foundation

/// D64: the lowest page↔loomd protocol (`internal/apiproto.Version`) this
/// Argo's page can use. The one window calls every dev machine's loomd
/// directly; a loomd below it is not connected (no route, no page work) and
/// the host shows only that it needs an upgrade, with an upgrade button. No
/// per-capability gates are restored for it (cap_gates B1). The shell is the
/// one gate: a host below it never gets a desktop route, so no page (in the
/// shell or a plain browser on the router) can reach it. A Go test checks this
/// against `internal/apiproto.Version`.
public enum LoomdAPI {
    public static let minimum = 1

    /// Why this hello's loomd cannot be used, or nil when it can. A missing
    /// field is protocol 0.
    public static func refusal(hello: GatewayHello, hostName: String) -> String? {
        let api = hello.api ?? 0
        guard api < minimum else { return nil }
        return "「\(hostName)」上的 Argo 太旧（协议 \(api)，这台 Argo 至少需要 \(minimum)），升级后才能接入"
    }
}
