#!/usr/bin/env python3
"""Build and stage the pinned personal libsignal dependency; no prebuilt download fallback."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from verify_libsignal import sha256, swift_source_digest, verify

IOS = Path(__file__).resolve().parents[2]
LOCK = IOS / 'ThirdParty/BConnectedLibsignal.lock.json'


def run(command, cwd=None, capture=False, env=None):
    return subprocess.run(command, cwd=cwd, env=env, check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def native_build_inputs(source, target, features):
    # Explicitly override CARGO_TARGET_DIR and build.target-dir; harvest only this path.
    target_directory = source / 'target'
    command = ['cargo', 'build', '--locked', '--target-dir', str(target_directory),
               '-p', 'libsignal-ffi', '--release', '--target', target,
               '--features', ','.join(features)]
    return command, target_directory / target / 'release/libsignal_ffi.a'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=IOS.parent / 'libsignal')
    args = parser.parse_args()
    source = args.source.resolve()
    lock = json.loads(LOCK.read_text())
    run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], source, True)
    revision = run(['git', 'rev-parse', 'HEAD'], source, True).strip()
    if revision != lock['revision']:
        raise ValueError('libsignal checkout must match revision ' + lock['revision'])
    if run(['git', 'status', '--porcelain', '--untracked-files=normal'], source, True).strip():
        raise ValueError('libsignal checkout must be clean before building pinned inputs')
    remote = run(['git', 'remote', 'get-url', 'origin'], source, True).strip()
    if remote.removesuffix('.git') != lock['repository'].removesuffix('.git'):
        raise ValueError('libsignal checkout must use the personal repository origin')
    for name, expected in lock['sourceHashes'].items():
        if sha256(source / name) != expected:
            raise ValueError('Pinned source hash mismatch: ' + name)
    if swift_source_digest(source / 'swift/Sources') != lock['swiftSourceTreeSha256']:
        raise ValueError('Swift/header source inventory differs from the reviewed source pin')
    sysroot = Path(run(['rustc', '--print', 'sysroot'], source, True).strip())
    host = re.search(r'^host: (.+)$', run(['rustc', '-vV'], source, True), re.M).group(1)
    nm = sysroot / 'lib/rustlib' / host / 'bin/llvm-nm'
    if not nm.is_file():
        raise ValueError('Install llvm-tools for the pinned Rust toolchain before preparing artifacts')
    output = IOS / '.build/bconnected-libsignal'
    staging = IOS / '.build/bconnected-libsignal-preparing'
    if staging.exists():
        shutil.rmtree(staging)
    staging.mkdir(parents=True)
    shutil.copytree(source / 'swift/Sources', staging / 'swift/Sources')
    shutil.copy2(source / 'LICENSE', staging / 'LICENSE')
    shutil.copy2(LOCK, staging / 'source-lock.json')
    shutil.copy2(IOS / 'ThirdParty/BConnectedLibSignalClient.podspec', staging / 'LibSignalClient.podspec')
    # Match the pinned Swift ABI: its simulator-only APIs require the testing bridge.
    # Device archives must never contain those exports.
    env = os.environ.copy()
    env.pop('RUSTFLAGS', None)
    env.pop('CARGO_ENCODED_RUSTFLAGS', None)
    env.pop('CARGO_TARGET_DIR', None)
    env['IPHONEOS_DEPLOYMENT_TARGET'] = lock['deploymentTarget']
    env['MACOSX_DEPLOYMENT_TARGET'] = lock['deploymentTarget']
    toolchain = IOS / '.build/bconnected-ios-toolchain.cmake'
    toolchain.write_text('set(CMAKE_OSX_DEPLOYMENT_TARGET "' + lock['deploymentTarget'] + '" CACHE STRING "BConnected minimum iOS" FORCE)\n')
    env['CMAKE_TOOLCHAIN_FILE'] = str(toolchain)
    shutil.copy2(toolchain, staging / 'native-toolchain.cmake')
    for platform, target in lock['targets'].items():
        command, archive = native_build_inputs(source, target, lock['features'][platform])
        run(command, source, env=env)
        load_commands = run(['xcrun', 'otool', '-l', str(archive)], source, True, env=env)
        versions = re.findall(r'\bminos\s+([\d.]+)', load_commands)
        version_tuple = lambda value: tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.')))
        if not versions or any(version_tuple(v) > version_tuple(lock['deploymentTarget']) for v in versions):
            raise ValueError('Native object minimum OS exceeds the pinned deployment target')
        symbols = run([str(nm), '--defined-only', '--extern-only', str(archive)], source, True)
        if not re.search(r'\b_signal_connection_manager_new_chat_only$', symbols, re.M):
            raise ValueError('Owned ChatOnlyNet constructor is missing from native archive')
        has_testing = bool(re.search(r'\b_signal_testing_', symbols))
        if has_testing != ('libsignal-bridge-testing' in lock['features'][platform]):
            raise ValueError('Native testing exports do not match target-specific features')
        if platform == 'iphoneos' and has_testing:
            raise ValueError('Native testing bridge is forbidden in device artifacts')
        destination = staging / 'native' / platform
        destination.mkdir(parents=True)
        shutil.copy2(archive, destination / 'libsignal_ffi.a')
    if run(['git', 'status', '--porcelain', '--untracked-files=normal'], source, True).strip():
        raise ValueError('Native build changed pinned source inputs')
    proof = {
        'revision': revision, 'repository': lock['repository'], 'features': lock['features'],
        'targets': lock['targets'], 'cargoTargetDirectory': 'source/target (explicit --target-dir)', 'deploymentTarget': lock['deploymentTarget'],
        'xcode': run(['xcodebuild', '-version'], source, True, env=env),
        'sdkBuilds': {platform: run(['xcrun', '--sdk', platform, '--show-sdk-build-version'], source, True, env=env).strip() for platform in lock['targets']},
        'rustc': run(['rustc', '-vV'], source, True),
        'files': {str(p.relative_to(staging)): sha256(p) for p in sorted(staging.rglob('*')) if p.is_file()},
    }
    (staging / 'provenance.json').write_text(json.dumps(proof, indent=2) + '\n')
    verify(staging, LOCK)
    if output.exists():
        shutil.rmtree(output)
    staging.rename(output)
    print('Prepared local dependency at ' + str(output))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit('error: ' + str(error))
