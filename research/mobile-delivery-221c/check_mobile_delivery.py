#!/usr/bin/env python3
"""Exercise actual AppModel/API delivery with private synthetic transport boundaries."""
import argparse
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--swiftc", required=True)
p.add_argument("--core-build", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output([a.swiftc, "--version"], text=True)
print(version, flush=True)
sources = []
for path in [Path("ios/Argo/Model") / (name + ".swift") for name in (
    "AppModel", "AgentSession", "AttachmentDraft", "ConversationState", "ModelRecoveryState", "NewSessionState"
)] + [Path("ios/Argo/Support/L10n.swift")]:
    text = path.read_text()
    if "Swift version 6.0." in version:
        text = re.sub(r"\bnonisolated (?=(?:struct|enum|class)\b)", "", text)
    target = a.output / path.name
    target.write_text(text)
    sources.append(str(target))
core = a.core_build / "debug"
objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
assert objects, "Build actual ArgoMobileKit before running this check"
binary = a.output / "mobile-delivery-check"
subprocess.run([a.swiftc, "-swift-version", "6", "-parse-as-library", "-j", "2", "-I", str(core / "Modules"),
                *map(str, objects), *sources, "research/mobile-delivery-221c/MobileDeliveryCheck.swift", "-o", str(binary)], check=True)
subprocess.run([str(binary.resolve())], check=True)
