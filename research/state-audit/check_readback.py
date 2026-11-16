#!/usr/bin/env python3
"""Compile and run real AppModel readback races on Linux (no iOS SDK).

First build ArgoMobileKit with swift build/test --jobs 2. Swift 6.0 needs
declaration-only `nonisolated` removed from temporary support-source copies;
its module already defaults to nonisolated. AppModel is always compiled as-is.
"""

import argparse
from pathlib import Path
import re
import subprocess


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--swiftc", required=True)
parser.add_argument("--core-build", type=Path, required=True)
parser.add_argument("--app-model", type=Path, default=Path("ios/Argo/Model/AppModel.swift"))
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output([args.swiftc, "--version"], text=True)
print(version, flush=True)
old_compiler = re.search(r"Swift version 6\.0\.", version) is not None
sources = []
model_dir = Path("ios/Argo/Model")
support = [model_dir / name for name in (
    "AgentSession.swift", "AttachmentDraft.swift", "ConversationState.swift",
    "ModelRecoveryState.swift", "NewSessionState.swift",
)] + [Path("ios/Argo/Support/L10n.swift")]
for source in support:
    if old_compiler:
        target = args.output / source.name
        target.write_text(re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", source.read_text()))
        sources.append(target)
    else:
        sources.append(source)
if old_compiler:
    print("Linux Swift 6.0: temporary support copies omit type-level nonisolated; AppModel is unchanged.", flush=True)
core = args.core_build / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
if not objects:
    raise SystemExit("Build ArgoMobileKit first; no core object files found.")
binary = args.output / "readback-check"
command = [args.swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2",
           "-I", str(core / "Modules"), *map(str, objects), *map(str, sources),
           str(args.app_model), "research/state-audit/ReadbackPollingCheck.swift", "-o", str(binary)]
subprocess.run(command, check=True)
raise SystemExit(subprocess.run([str(binary.resolve())]).returncode)
