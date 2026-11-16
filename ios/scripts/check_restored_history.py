#!/usr/bin/env python3
"""Run production restored-history models with synthetic, cancellable HTTP boundaries.

Requires an already-built ArgoMobileKit containing nativeSources. No network,
UIKit, clipboard or real host files are used. All runtime data stays in --output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

from notification_test_support import notification_sources

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", required=True)
    parser.add_argument("--core-build", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    compiler = shutil.which(args.swiftc)
    if not compiler:
        parser.error("Swift compiler not found")
    core = args.core_build.resolve()
    objects = sorted((core / "ArgoMobileKit.build").glob("*.o"))
    if not objects or not (core / "Modules/ArgoMobileKit.swiftmodule").exists():
        parser.error("--core-build must contain ArgoMobileKit objects and module")
    output = args.output.resolve()
    for directory in [output, output / "runtime", output / "tmp", output / "cache", output / "sources"]:
        directory.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, TMPDIR=str(output / "tmp"), XDG_CACHE_HOME=str(output / "cache"),
               CLANG_MODULE_CACHE_PATH=str(output / "cache/clang"))
    sources = sorted((ROOT / "ios/Argo/Model").glob("*.swift"))
    sources += [ROOT / "ios/Argo/Support/L10n.swift", ROOT / "ios/Argo/Verification/RestoredHistoryCheck.swift"]
    source_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}

    def save(name, source):
        path = output / "sources" / name
        path.write_text(source)
        source_hashes["generated/" + name] = hashlib.sha256(path.read_bytes()).hexdigest()
        return path

    sources.extend(notification_sources(lambda path: (ROOT / path).read_text(), save))
    binary = output / "restored-history-check"
    command = [os.path.abspath(compiler), "-swift-version", "6", "-parse-as-library", "-j", "2",
               "-module-cache-path", str(output / "cache/modules"), "-I", str(core / "Modules"),
               *map(str, objects), *map(str, sources), "-o", str(binary)]
    manifest = {"revision": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "compiler": subprocess.check_output([compiler, "--version"], text=True).strip(),
                "command": command, "sources": source_hashes}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    with (output / "compile.log").open("w") as log:
        subprocess.run(command, cwd=output / "runtime", env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    result = subprocess.run([str(binary)], cwd=output / "runtime", env=env, capture_output=True, text=True, timeout=120)
    text = result.stdout + result.stderr
    (output / "run.log").write_text(text + f"exit={result.returncode}\n")
    print(text, end="")
    return 0 if result.returncode == 0 and "Restored history:" in text and "FAIL " not in text else 1


if __name__ == "__main__":
    raise SystemExit(main())
