#!/usr/bin/env python3
"""Verify staged local inputs. This script never downloads or substitutes artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def swift_source_digest(source_root):
    if source_root.is_symlink() or any(p.is_symlink() for p in source_root.rglob('*')):
        raise ValueError('Swift/header source tree cannot contain symlinks')
    files = {p.relative_to(source_root).as_posix(): sha256(p) for p in source_root.rglob('*') if p.is_file()}
    canonical = json.dumps(files, sort_keys=True, separators=(',', ':')).encode('utf-8')
    return hashlib.sha256(canonical).hexdigest()


def verify(root, expected_lock, platform=None):
    if root.is_symlink() or any(p.is_symlink() for p in root.rglob('*')):
        raise ValueError('Symlinks are not allowed in staged dependency inputs')
    lock = json.loads(expected_lock.read_text())
    if json.loads((root / 'source-lock.json').read_text()) != lock:
        raise ValueError('Staged source lock differs from the current repository-owned lock')
    if swift_source_digest(root / 'swift/Sources') != lock['swiftSourceTreeSha256']:
        raise ValueError('Staged Swift/header tree differs from the reviewed source pin')
    expected_podspec = expected_lock.with_name('BConnectedLibSignalClient.podspec')
    if sha256(root / 'LibSignalClient.podspec') != sha256(expected_podspec):
        raise ValueError('Staged podspec differs from the current repository-owned packaging policy')
    proof = json.loads((root / 'provenance.json').read_text())
    for field in ['repository', 'revision', 'features', 'targets', 'deploymentTarget']:
        if proof[field] != lock[field]:
            raise ValueError('Native provenance differs from the personal source lock: ' + field)
    if platform and platform not in lock['targets']:
        raise ValueError('Only arm64 iPhone and iPhone simulator inputs are prepared')
    if any(Path(name).is_absolute() or '..' in Path(name).parts for name in proof['files']):
        raise ValueError('Invalid path in staged input inventory')
    actual = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p != root / 'provenance.json'}
    if actual != set(proof['files']):
        raise ValueError('Staged input inventory differs from the prepared manifest')
    for name, expected in proof['files'].items():
        path = root / name
        if path.is_symlink() or not path.is_file() or sha256(path) != expected:
            raise ValueError('Missing or mismatched pinned input: ' + name)
    for name, expected in lock['sourceHashes'].items():
        if name.startswith('swift/') and sha256(root / name) != expected:
            raise ValueError('Swift/header input differs from pinned source: ' + name)
    if platform and proof['targets'].get(platform) != lock['targets'][platform]:
        raise ValueError('Requested native target was not prepared')
    if platform and not (root / 'native' / platform / 'libsignal_ffi.a').is_file():
        raise ValueError('Missing requested native archive')
    flags = os.environ.get('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '') + os.environ.get('OTHER_SWIFT_FLAGS', '')
    if 'BCONNECTED_COMPILE_VALIDATION' in flags or os.environ.get('BCONNECTED_COMPILE_VALIDATION') == 'YES':
        if platform != 'iphonesimulator' or os.environ.get('CONFIGURATION') != 'Debug' or os.environ.get('ACTION') != 'build':
            raise ValueError('Compile validation is only allowed for Debug simulator build, never archive/install/device')
    print('Verified pinned personal libsignal source/header/native inputs; no download fallback.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--platform')
    parser.add_argument('--lock', type=Path, default=Path(__file__).resolve().parents[2] / 'ThirdParty/BConnectedLibsignal.lock.json')
    args = parser.parse_args()
    try:
        verify(args.root.absolute(), args.lock, args.platform)
    except (KeyError, OSError, ValueError) as error:
        sys.exit('error: ' + str(error))
