"""Compile real AppModel/filter logic and the production badge projection on Linux.

Reuses the existing Core build. Swift 6.0 compatibility copies remove only
type-level nonisolated; badge style types are stubs, its count body is original.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ios/scripts"))
from notification_test_support import write_notification_sources


ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent


def block(source, marker):
    start = source.index("{", source.index(marker))
    end, depth = start + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Fixed Git revision; defaults to working tree")
    parser.add_argument("--expect-baseline-bug", action="store_true")
    parser.add_argument("--swiftc", default=os.environ.get("ARGO_UNREAD_SWIFTC", "swiftc"),
                        help="Swift compiler (default: ARGO_UNREAD_SWIFTC or swiftc on PATH)")
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if compiler is None:
        parser.error(f"Swift compiler not found: {args.swiftc}; use --swiftc, ARGO_UNREAD_SWIFTC or PATH")

    def read(path):
        if args.revision:
            return subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    core = next(path for path in (ROOT / "ios/Packages/ArgoMobileKit/.build").glob("*/debug")
                if (path / "Modules/ArgoMobileKit.swiftmodule").is_file())
    sources = ["Model/AgentSession.swift", "Model/AttachmentDraft.swift", "Model/ConversationState.swift",
               "Model/ModelRecoveryState.swift", "Model/NewSessionState.swift", "Support/L10n.swift", "Model/AppModel.swift"]
    with tempfile.TemporaryDirectory(prefix="build-", dir=OUT) as directory:
        build = Path(directory)
        inputs = []
        for relative in sources:
            text = read("ios/Argo/" + relative)
            text = re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", text)
            path = build / Path(relative).name
            path.write_text(text)
            inputs.append(str(path))
        inputs.extend(map(str, write_notification_sources(build, read)))
        badges = block(read("ios/Argo/Views/Chats/ChatsView.swift"), "private var filterItems:")
        projection = build / "BadgeProjection.swift"
        projection.write_text("""
struct CapsuleFilterItemData {
    let id: String
    let title: String
    let count: Int
    let tone: String?
    let symbol: String?
}
extension AgentState { var tone: String { rawValue } }
@MainActor struct BadgeProjection {
    let model: AppModel
    var filterItems: [CapsuleFilterItemData] {
""" + badges + "\n}\n}\n")
        executable = build / "unread-check"
        command = [compiler, "-swift-version", "6", "-parse-as-library", "-j", "2", "-I", str(core / "Modules"),
                   *map(str, sorted((core / "ArgoMobileKit.build").glob("*.o"))), *inputs,
                   str(projection), str(OUT / "UnreadCheck.swift"), "-o", str(executable)]
        subprocess.run(command, cwd=ROOT, check=True)
        run = [str(executable)] + (["--expect-baseline-bug"] if args.expect_baseline_bug else [])
        subprocess.run(run, cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
