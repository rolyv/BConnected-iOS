// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import XCTest
@testable import SignalServiceKit

final class BConnectedRegistrationKeyCommitmentTest: XCTestCase {
    private typealias Commitment = BConnectedRegistrationKeyCommitment
    private let expected = "3b5817c63cb5ba35e0a6d1bd8b4323381de46a585b3f0ca52eb945cd831f8fd5"

    // An exact copy of Signal-Server's public-only cross-language fixture. No private keys.
    private struct Fixture: Decodable {
        struct Key: Decodable {
            var keyId: Int64
            var publicKey: Data
            var signature: Data

            func ec() throws -> Commitment.SignedECPreKey {
                .init(keyId: keyId, publicKey: try PublicKey(publicKey), signature: signature)
            }

            func kem() throws -> Commitment.SignedKEMPreKey {
                .init(keyId: keyId, publicKey: try KEMPublicKey(publicKey), signature: signature)
            }
        }

        var aciIdentityKey: Data
        var pniIdentityKey: Data
        var aciRegistrationId: Int
        var pniRegistrationId: Int
        var aciSignedPreKey: Key
        var pniSignedPreKey: Key
        var aciPqLastResortPreKey: Key
        var pniPqLastResortPreKey: Key
        var transcriptBase64: Data
        var sha256: String

        func aci() throws -> Commitment.IdentityMaterial {
            .init(identityKey: try IdentityKey(bytes: aciIdentityKey), registrationId: aciRegistrationId,
                  signedPreKey: try aciSignedPreKey.ec(), lastResortPreKey: try aciPqLastResortPreKey.kem())
        }

        func pni() throws -> Commitment.IdentityMaterial {
            .init(identityKey: try IdentityKey(bytes: pniIdentityKey), registrationId: pniRegistrationId,
                  signedPreKey: try pniSignedPreKey.ec(), lastResortPreKey: try pniPqLastResortPreKey.kem())
        }

        func compute() throws -> String { try Commitment.compute(aci: aci(), pni: pni()) }
    }

    private func fixture() throws -> Fixture {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Self.self)
        #endif
        let url = try XCTUnwrap(bundle.url(forResource: "registration-key-commitment-v1", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testMatchesEveryByteOfServerTranscriptAndDigest() throws {
        let f = try fixture()
        let transcript = try Commitment.transcript(aci: f.aci(), pni: f.pni())
        XCTAssertEqual(transcript.count, 3662)
        XCTAssertEqual(transcript, f.transcriptBase64)
        XCTAssertEqual(try f.compute(), f.sha256)
        XCTAssertEqual(try f.compute(), expected)
    }

    func testDeterministicAcrossNativeObjectsAndDoesNotMutatePublicValues() throws {
        let f = try fixture()
        let aci = try f.aci()
        let originalSignature = aci.signedPreKey.signature
        let originalKey = aci.signedPreKey.publicKey.serialize()
        XCTAssertEqual(try Commitment.compute(aci: aci, pni: f.pni()), expected)
        XCTAssertEqual(try Commitment.compute(aci: aci, pni: f.pni()), expected)
        XCTAssertEqual(try fixture().compute(), expected)
        XCTAssertEqual(aci.signedPreKey.signature, originalSignature)
        XCTAssertEqual(aci.signedPreKey.publicKey.serialize(), originalKey)
    }

    func testEveryNumericFieldIsBoundIncludingServerBoundaryKeyIds() throws {
        let changes: [(inout Fixture) -> Void] = [
            { $0.aciRegistrationId = 2 }, { $0.pniRegistrationId = 16382 },
            { $0.aciSignedPreKey.keyId = 1 }, { $0.pniSignedPreKey.keyId = 2147483646 },
            { $0.aciPqLastResortPreKey.keyId = 0 }, { $0.pniPqLastResortPreKey.keyId = 2147483647 },
        ]
        for change in changes {
            var f = try fixture()
            change(&f)
            XCTAssertNotEqual(try f.compute(), expected)
        }
    }

    func testRejectsOutOfRangeRegistrationIdsAndPreKeyIds() throws {
        for invalid in [-1, 0, 16384, Int.max] {
            var f = try fixture()
            f.aciRegistrationId = invalid
            assertInvalid(f)
            f = try fixture()
            f.pniRegistrationId = invalid
            assertInvalid(f)
        }
        for invalid in [Int64(-1), 2147483648, Int64.max] {
            let changes: [(inout Fixture) -> Void] = [
                { $0.aciSignedPreKey.keyId = invalid }, { $0.pniSignedPreKey.keyId = invalid },
                { $0.aciPqLastResortPreKey.keyId = invalid }, { $0.pniPqLastResortPreKey.keyId = invalid },
            ]
            for change in changes {
                var f = try fixture()
                change(&f)
                assertInvalid(f)
            }
        }
    }

    func testAciPniOrderingIsBoundEvenWithValidSignatures() throws {
        let f = try fixture()
        XCTAssertNotEqual(try Commitment.compute(aci: f.pni(), pni: f.aci()), expected)
    }

    func testRejectsWrongIdentityAndEachAlteredSignature() throws {
        let changes: [(inout Fixture) -> Void] = [
            { $0.aciIdentityKey = $0.pniIdentityKey }, { $0.pniIdentityKey = $0.aciIdentityKey },
            { $0.aciSignedPreKey.signature[0] ^= 1 }, { $0.pniSignedPreKey.signature[0] ^= 1 },
            { $0.aciPqLastResortPreKey.signature[0] ^= 1 }, { $0.pniPqLastResortPreKey.signature[0] ^= 1 },
            { $0.aciSignedPreKey.publicKey = $0.pniSignedPreKey.publicKey },
            { $0.pniPqLastResortPreKey.publicKey = $0.aciPqLastResortPreKey.publicKey },
        ]
        for change in changes {
            var f = try fixture()
            change(&f)
            assertInvalid(f)
        }
    }

    func testRejectsEveryMalformedSignatureLength() throws {
        for size in [0, 63, 65, 1024] {
            let bad = Data(repeating: 0, count: size)
            let changes: [(inout Fixture) -> Void] = [
                { $0.aciSignedPreKey.signature = bad }, { $0.pniSignedPreKey.signature = bad },
                { $0.aciPqLastResortPreKey.signature = bad }, { $0.pniPqLastResortPreKey.signature = bad },
            ]
            for change in changes {
                var f = try fixture()
                change(&f)
                assertInvalid(f)
            }
        }
    }

    func testTypedBoundaryUsesNativeParsersForMalformedKeyEncodings() throws {
        let f = try fixture()
        // Invalid byte encodings cannot construct the helper's required public-key types.
        XCTAssertThrowsError(try IdentityKey(bytes: Data()))
        XCTAssertThrowsError(try PublicKey(Data(f.aciSignedPreKey.publicKey.dropLast())))
        XCTAssertThrowsError(try PublicKey(f.aciPqLastResortPreKey.publicKey))
        XCTAssertThrowsError(try KEMPublicKey(Data(f.aciPqLastResortPreKey.publicKey.dropLast())))
        XCTAssertThrowsError(try KEMPublicKey(f.aciSignedPreKey.publicKey))
    }

    func testRecordAdaptersAndNewValidSignaturesUseOnlyPublicMaterial() throws {
        let identity = IdentityKeyPair.generate()
        let ec = PrivateKey.generate()
        let kem = KEMKeyPair.generate()
        let ecRecord = try SignedPreKeyRecord(id: 0, timestamp: 123, privateKey: ec,
            signature: identity.privateKey.generateSignature(message: ec.publicKey.serialize()))
        let kemRecord = try KyberPreKeyRecord(id: 2147483647, timestamp: 456, keyPair: kem,
            signature: identity.privateKey.generateSignature(message: kem.publicKey.serialize()))
        let ecPublic = try Commitment.SignedECPreKey(ecRecord)
        let kemPublic = try Commitment.SignedKEMPreKey(kemRecord)
        XCTAssertEqual(ecPublic.publicKey.serialize(), ec.publicKey.serialize())
        XCTAssertEqual(kemPublic.publicKey.serialize(), kem.publicKey.serialize())
        let material = Commitment.IdentityMaterial(identityKey: identity.identityKey, registrationId: 1,
            signedPreKey: ecPublic, lastResortPreKey: kemPublic)
        let pni = try fixture().pni()
        let original = try Commitment.compute(aci: material, pni: pni)
        XCTAssertNotEqual(original, expected)
        let newSignature = identity.privateKey.generateSignature(message: ecPublic.publicKey.serialize())
        XCTAssertNotEqual(newSignature, ecPublic.signature)
        let changed = Commitment.IdentityMaterial(identityKey: identity.identityKey, registrationId: 1,
            signedPreKey: .init(keyId: ecPublic.keyId, publicKey: ecPublic.publicKey, signature: newSignature),
            lastResortPreKey: kemPublic)
        XCTAssertNotEqual(try Commitment.compute(aci: changed, pni: pni), original)

        let tooLarge = try SignedPreKeyRecord(id: UInt32.max, timestamp: 123, privateKey: ec,
            signature: ecRecord.signature)
        let invalid = Commitment.IdentityMaterial(identityKey: identity.identityKey, registrationId: 1,
            signedPreKey: try .init(tooLarge), lastResortPreKey: kemPublic)
        XCTAssertThrowsError(try Commitment.compute(aci: invalid, pni: pni))
    }

    private func assertInvalid(_ f: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try f.compute(), file: file, line: line) { error in
            XCTAssertEqual(error as? Commitment.ValidationError, .invalidRegistrationKeys, file: file, line: line)
            XCTAssertEqual(String(describing: error), "Registration public-key material is invalid", file: file, line: line)
        }
    }
}
