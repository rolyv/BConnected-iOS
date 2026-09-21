import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from verify_libsignal import sha256, swift_source_digest, verify
from prepare_libsignal import native_build_inputs


class VerifyLibsignalTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'stage'
        self.root.mkdir()
        self.lock = Path(self.directory.name) / 'authoritative-lock.json'
        native = self.root / 'native/iphonesimulator/libsignal_ffi.a'
        native.parent.mkdir(parents=True)
        native.write_bytes(b'synthetic archive')
        swift = self.root / 'swift/Sources/LibSignalClient/Net.swift'
        swift.parent.mkdir(parents=True)
        swift.write_text('reviewed Swift source')
        lock = {'swiftSourceTreeSha256': swift_source_digest(self.root / 'swift/Sources'), 'repository': 'personal-fixture', 'revision': 'fixture', 'features': {'iphonesimulator': ['testing']}, 'deploymentTarget': '15.0', 'sourceHashes': {},
                'targets': {'iphonesimulator': 'aarch64-apple-ios-sim'}}
        self.lock.write_text(json.dumps(lock))
        self.lock.with_name('BConnectedLibSignalClient.podspec').write_text('fixture podspec')
        (self.root / 'LibSignalClient.podspec').write_text('fixture podspec')
        (self.root / 'source-lock.json').write_text(json.dumps(lock))
        proof = dict(lock)
        proof['files'] = {str(p.relative_to(self.root)): sha256(p) for p in self.root.rglob('*') if p.is_file()}
        (self.root / 'provenance.json').write_text(json.dumps(proof))

    def testExactPreparedInputsPass(self):
        verify(self.root, self.lock, 'iphonesimulator')

    def testMissingOrChangedNativeArchiveFails(self):
        native = self.root / 'native/iphonesimulator/libsignal_ffi.a'
        native.write_bytes(b'changed')
        with self.assertRaises(ValueError): verify(self.root, self.lock, 'iphonesimulator')
        native.unlink()
        with self.assertRaises(ValueError): verify(self.root, self.lock, 'iphonesimulator')

    def testExtraUnverifiedSourceFails(self):
        (self.root / 'surprise.swift').write_text('unverified')
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testMissingTargetFailsRatherThanSubstituting(self):
        with self.assertRaises(ValueError): verify(self.root, self.lock, 'iphoneos')

    def testMismatchedSourceRevisionFails(self):
        proof = json.loads((self.root / 'provenance.json').read_text())
        proof['revision'] = 'different'
        (self.root / 'provenance.json').write_text(json.dumps(proof))
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testPerTargetFeaturesAndDeploymentMetadataCannotDrift(self):
        path = self.root / 'provenance.json'
        original = json.loads(path.read_text())
        for field, value in [('features', {'iphonesimulator': ['wrong-features']}), ('deploymentTarget', '27.0'), ('repository', 'upstream-fixture')]:
            changed = dict(original)
            changed[field] = value
            path.write_text(json.dumps(changed))
            with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testStalePodspecFailsAgainstCurrentPackagingPolicy(self):
        self.lock.with_name('BConnectedLibSignalClient.podspec').write_text('new reviewed podspec')
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testStaleStagingFailsAgainstCurrentRepositoryLock(self):
        current = json.loads(self.lock.read_text())
        current['revision'] = 'new-reviewed-revision'
        self.lock.write_text(json.dumps(current))
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testDirectorySymlinksCannotIntroduceUnverifiedSources(self):
        outside = Path(self.directory.name) / 'outside'
        outside.mkdir()
        (outside / 'unexpected.swift').write_text('unverified')
        (self.root / 'unverified-sources').symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testInventoryPathTraversalFails(self):
        proof = json.loads((self.root / 'provenance.json').read_text())
        proof['files']['../authoritative-lock.json'] = sha256(self.lock)
        (self.root / 'provenance.json').write_text(json.dumps(proof))
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testMutatedSwiftSourceCannotBeBlessedByUpdatingLocalReceipt(self):
        name = 'swift/Sources/LibSignalClient/Net.swift'
        (self.root / name).write_text('different source')
        path = self.root / 'provenance.json'
        proof = json.loads(path.read_text())
        proof['files'][name] = sha256(self.root / name)
        path.write_text(json.dumps(proof))
        with self.assertRaises(ValueError): verify(self.root, self.lock)

    def testExplicitCargoTargetDirectoryMatchesHarvestDespiteEnvironmentOverride(self):
        source = Path(self.directory.name) / 'personal-source'
        with patch.dict(os.environ, {'CARGO_TARGET_DIR': '/different/old-target'}):
            command, artifact = native_build_inputs(source, 'aarch64-apple-ios', ['production'])
        self.assertEqual(command.count('--target-dir'), 1)
        explicit = Path(command[command.index('--target-dir') + 1])
        self.assertEqual(explicit, source / 'target')
        self.assertEqual(artifact, explicit / 'aarch64-apple-ios/release/libsignal_ffi.a')
        self.assertIn('--locked', command)

    def testCompileValidationRejectsReleaseAndArchive(self):
        for configuration, action in [('Release', 'build'), ('Debug', 'install'), ('Debug', 'archive')]:
            with patch.dict(os.environ, {'BCONNECTED_COMPILE_VALIDATION': 'YES', 'CONFIGURATION': configuration, 'ACTION': action}):
                with self.assertRaises(ValueError): verify(self.root, self.lock, 'iphonesimulator')
        with patch.dict(os.environ, {'BCONNECTED_COMPILE_VALIDATION': 'YES', 'CONFIGURATION': 'Debug', 'ACTION': 'build'}):
            verify(self.root, self.lock, 'iphonesimulator')


if __name__ == '__main__':
    unittest.main()
