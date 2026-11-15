import Foundation

/// IN-11: a direct pairing that cannot reach the gateway only said 「超时」.
/// The code carries the address `loomd pair` picked (the default route's), and
/// a cloud dev machine reached over a VPN is often not reachable there, or its
/// port is filtered. The hint names both ways out.
public enum PairingReachability {
    /// What `describe(NWError)` says for these POSIX errors; shared so the
    /// classification below does not depend on copied text.
    public static let connectTimedOut = "连接超时（检查网络，或远程防火墙是否放行网关端口）"
    public static let networkUnreachable = "网络不可达"

    /// The text the pairing sheet shows for `error` from pairing with `text`.
    public static func message(for error: Error, code text: String) -> String {
        let base = error.localizedDescription
        guard !text.contains(TailcatCode.prefix), let code = try? PairingCode(parsing: text),
              isUnreachable(error) else { return base }
        return base + "\n" + hint(host: code.host, port: code.port)
    }

    static func isUnreachable(_ error: Error) -> Bool {
        switch error as? GatewayError {
        case .timeout: return true
        case .network(let detail): return detail == connectTimedOut || detail == networkUnreachable
        default: return false
        }
    }

    public static func hint(host: String, port: Int) -> String {
        "确认这台 Mac 能访问 \(host):\(port)。地址不对（远程有多块网卡、经 VPN 访问）时，在远程执行 \(RemoteHint.command("pair --host <Mac 能访问的地址>")) 生成新配对码；"
            + "端口被防火墙挡住时，加上 --transport tailcat 重新执行 pair 命令，改用 Tailcat 连接。"
    }
}
