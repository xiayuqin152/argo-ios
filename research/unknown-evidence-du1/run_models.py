#!/usr/bin/env python3
"""Compile unchanged production models and run synthetic I/O boundary fixtures."""
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
p.add_argument("--expect-erased", action="store_true")
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
swiftc = shutil.which(a.swiftc)
if swiftc is None:
    p.error(f"Swift compiler not found: {a.swiftc}")
core = a.core_build / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
assert objects, "Build the actual Core/API package first"
sources = [Path("ios/Argo/Model") / (name + ".swift") for name in (
    "AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"
)] + [Path("ios/Argo/Support/L10n.swift")]
sources.extend(write_notification_sources(a.output, lambda path: Path(path).read_text()))
binary = a.output / "model-check"
with (a.output / "compile.log").open("w") as log:
    subprocess.run([swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2", "-I", str(core / "Modules"),
                    *map(str, objects), *map(str, sources), str(a.fixture), "-o", str(binary)],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
with (a.output / "run.log").open("w") as log:
    result = subprocess.run([str(binary.resolve())], stdout=log, stderr=subprocess.STDOUT)
    log.write(f"exit={result.returncode}\n")
output = (a.output / "run.log").read_text()
print(output, end="")
if a.expect_erased:
    assert result.returncode == 1
    assert "FAIL unboundUnknownRemoved: observed_unknown_erased_after_id_binding" in output
    assert "status=queued" in output and "writes=1, queueCount=0" in output
    assert "Mobile delivery: 0/1 passed" in output
    print("PASS baseline verification: expected exit=1 and exact DU-1 assertion; writes=1")
else:
    assert result.returncode == 0, "Model acceptance failed; see preserved run.log"
