#!/usr/bin/env python3
"""Compile checkout models and run synthetic I/O fixtures under output/runtime."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ios/scripts"))
from notification_test_support import write_notification_sources

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("fixture", type=Path)
p.add_argument("--output", type=Path, required=True)
p.add_argument("--swiftc", required=True)
p.add_argument("--core-build", type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
a.fixture = a.fixture.resolve()
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=True)
swiftc = shutil.which(a.swiftc)
if swiftc is None:
    p.error(f"Swift compiler not found: {a.swiftc}")
core = a.core_build.resolve() / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
assert objects, "Build the actual Core/API package first"
sources = [root / "ios/Argo/Model" / (name + ".swift") for name in (
    "AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"
)] + [root / "ios/Argo/Support/L10n.swift"]
sources.extend(write_notification_sources(a.output, lambda path: (root / path).read_text()))
binary = a.output / "model-check"
with (a.output / "compile.log").open("w") as log:
    subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2", "-I", str(core / "Modules"),
                    *map(str, objects), *map(str, sources), str(a.fixture), "-o", str(binary)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
runtime = a.output / "runtime"
runtime.mkdir(exist_ok=True)
with (a.output / "run.log").open("w") as log:
    result = subprocess.run([str(binary)], cwd=runtime, stdout=log, stderr=subprocess.STDOUT)
    log.write(f"exit={result.returncode}\n")
output = (a.output / "run.log").read_text()
print(output, end="")
assert result.returncode == 0, "Model acceptance failed; see preserved run.log"
