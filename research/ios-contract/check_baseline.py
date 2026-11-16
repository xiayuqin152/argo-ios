#!/usr/bin/env python3
"""Require the fixed fixture to reproduce the original failure at the task base."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASE = 'a5e9691a0713d00a8ba92211cc79fd93ef48b533'
SOURCE = 'ios/Argo/Model/ModelRecoveryState.swift'
PACKAGE = 'ios/Packages/ArgoMobileKit'


def main():
    build = Path(subprocess.check_output(
        ['swift', 'build', '--package-path', PACKAGE, '--show-bin-path'], cwd=ROOT, text=True).strip())
    with tempfile.TemporaryDirectory(prefix='model-recovery-baseline-', dir=build) as scratch:
        scratch = Path(scratch)
        source = scratch / 'ModelRecoveryState.swift'
        source.write_bytes(subprocess.check_output(['git', 'show', f'{BASE}:{SOURCE}'], cwd=ROOT))
        binary = scratch / 'check'
        args = ['swiftc', '-j', '2', '-I', str(build / 'Modules')]
        args += [str(p) for p in sorted((build / 'ArgoMobileKit.build').glob('*.swift.o'))]
        args += [str(source), 'research/ios-contract/ModelRecoveryCheckSupport.swift',
                 'research/ios-contract/WireContractCheck.swift', 'research/ios-contract/ModelRecoveryCheck.swift',
                 '-o', str(binary)]
        subprocess.run(args, cwd=ROOT, check=True)
        result = subprocess.run([str(binary)], cwd=ROOT, text=True, capture_output=True)
        (ROOT / 'research/ios-contract/probe-baseline.log').write_text(
            f'base={BASE}\nexit={result.returncode}\n' + result.stdout + result.stderr)
        assert result.returncode == 1, f'expected exit 1, got {result.returncode}'
        assert 'FAIL: unconfirmed /model receipt permits another model write after unavailable native readback' in result.stdout
        assert 'CHECK_FAILED: retryBeforeReview' in result.stdout
    print('PASS: baseline exits 1 at the expected unavailable-readback assertion')


if __name__ == '__main__':
    main()
