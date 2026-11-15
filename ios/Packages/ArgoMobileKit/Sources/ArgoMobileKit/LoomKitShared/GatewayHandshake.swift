import Foundation

/// A gateway connection the far end closed during its TLS handshake. The
/// gateway does that, without a reply, to a banned address (closed at accept)
/// and to an address over its pre-auth connection limit; a proxy or virtual
/// network card can do the same to short connections.
public enum GatewayHandshake {
    public static let closedHint = "常见原因：这台 Mac 的出口地址失败次数过多，被网关暂时封禁（10 分钟后自动解除，远程上 Argo「设置 › 网络 › 网关」可以立即解除）；同一出口地址同时新建的连接超过网关限制；或代理/虚拟网卡拦截了短连接"

    /// errSSLClosedGraceful and errSSLClosedAbort.
    static let closedTLSStatuses: Set<Int32> = [-9805, -9806]

    /// Whether a POSIX error or a TLS status means the peer hung up mid-handshake.
    public static func isClosed(posix: Int32? = nil, tlsStatus: Int32? = nil) -> Bool {
        if let posix, posix == POSIXErrorCode.ECONNRESET.rawValue { return true }
        if let tlsStatus { return closedTLSStatuses.contains(tlsStatus) }
        return false
    }
}
