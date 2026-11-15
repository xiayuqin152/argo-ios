import Foundation

/// How copy tells the user to run a command on a remote. The remote may still
/// run Argo 1.0.9, whose program is called loomd and has no `argo` command until
/// the Mac has upgraded it (which needs pairing first), so an instruction to
/// run something there names both.
public enum RemoteHint {
    /// `argo <args>`, and the same command under the name an older remote has.
    public static func command(_ args: String) -> String {
        "argo \(args)（旧版远程用 loomd \(args)）"
    }
}
