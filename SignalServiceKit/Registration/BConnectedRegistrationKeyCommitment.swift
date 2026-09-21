// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
public import Foundation
public import LibSignalClient

/// The public-key transcript shared with Signal-Server's RegistrationKeyCommitment.
/// This proves neither phone possession nor membership. Registration must separately bind the
/// resulting commitment to the exact persisted keys and the complete immutable request.
public enum BConnectedRegistrationKeyCommitment {
    public enum ValidationError: Error, Equatable, CustomStringConvertible {
        case invalidRegistrationKeys

        public var description: String { "Registration public-key material is invalid" }
    }

    public struct SignedECPreKey {
        public let keyId: Int64
        public let publicKey: LibSignalClient.PublicKey
        public let signature: Data

        public init(keyId: Int64, publicKey: LibSignalClient.PublicKey, signature: Data) {
            self.keyId = keyId
            self.publicKey = publicKey
            self.signature = signature
        }

        /// Reads only public material; never serializes the private-key-bearing record.
        public init(_ record: SignedPreKeyRecord) throws {
            do {
                self.init(keyId: Int64(record.id), publicKey: try record.publicKey(), signature: record.signature)
            } catch {
                throw ValidationError.invalidRegistrationKeys
            }
        }
    }

    public struct SignedKEMPreKey {
        public let keyId: Int64
        public let publicKey: LibSignalClient.KEMPublicKey
        public let signature: Data

        public init(keyId: Int64, publicKey: LibSignalClient.KEMPublicKey, signature: Data) {
            self.keyId = keyId
            self.publicKey = publicKey
            self.signature = signature
        }

        /// Reads only public material; never serializes the private-key-bearing record.
        public init(_ record: KyberPreKeyRecord) throws {
            do {
                self.init(keyId: Int64(record.id), publicKey: try record.publicKey(), signature: record.signature)
            } catch {
                throw ValidationError.invalidRegistrationKeys
            }
        }
    }

    public struct IdentityMaterial {
        public let identityKey: IdentityKey
        public let registrationId: Int
        public let signedPreKey: SignedECPreKey
        public let lastResortPreKey: SignedKEMPreKey

        public init(
            identityKey: IdentityKey,
            registrationId: Int,
            signedPreKey: SignedECPreKey,
            lastResortPreKey: SignedKEMPreKey
        ) {
            self.identityKey = identityKey
            self.registrationId = registrationId
            self.signedPreKey = signedPreKey
            self.lastResortPreKey = lastResortPreKey
        }
    }

    /// Lowercase SHA-256 hex. Both ACI and PNI material are mandatory for the phone pilot.
    public static func compute(aci: IdentityMaterial, pni: IdentityMaterial) throws -> String {
        let digest = SHA256.hash(data: try transcript(aci: aci, pni: pni))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // Kept internal so the shared test vector checks every byte, not just its digest.
    static func transcript(aci: IdentityMaterial, pni: IdentityMaterial) throws -> Data {
        do {
            let aci = try snapshot(aci)
            let pni = try snapshot(pni)
            var result = Data("bconnected.registration-keys.v1\0".utf8)
            let fields = [aci.identity, pni.identity, aci.registrationId, pni.registrationId]
                + aci.ec + pni.ec + aci.kem + pni.kem
            for field in fields {
                guard let size = UInt32(exactly: field.count) else {
                    throw ValidationError.invalidRegistrationKeys
                }
                result.append(bigEndian(size))
                result.append(field)
            }
            return result
        } catch {
            // Do not expose parser errors or key fragments in the error value.
            throw ValidationError.invalidRegistrationKeys
        }
    }

    private struct Snapshot {
        let identity: Data
        let registrationId: Data
        let ec: [Data]
        let kem: [Data]
    }

    private static func snapshot(_ material: IdentityMaterial) throws -> Snapshot {
        // Match RegistrationIdValidator and KeyIdUtil, including key ID zero and 2^31 - 1.
        guard (1...16383).contains(material.registrationId),
              (0...Int64(Int32.max)).contains(material.signedPreKey.keyId),
              (0...Int64(Int32.max)).contains(material.lastResortPreKey.keyId),
              material.signedPreKey.signature.count == 64,
              material.lastResortPreKey.signature.count == 64 else {
            throw ValidationError.invalidRegistrationKeys
        }

        // Snapshot public values, reparse with libsignal, and verify precisely what is hashed.
        let identityBytes = material.identityKey.serialize()
        let ecBytes = material.signedPreKey.publicKey.serialize()
        let kemBytes = material.lastResortPreKey.publicKey.serialize()
        let ecSignature = material.signedPreKey.signature
        let kemSignature = material.lastResortPreKey.signature
        let identity = try IdentityKey(bytes: identityBytes)
        let ec = try LibSignalClient.PublicKey(ecBytes)
        let kem = try LibSignalClient.KEMPublicKey(kemBytes)
        guard identity.serialize() == identityBytes,
              ec.serialize() == ecBytes,
              kem.serialize() == kemBytes,
              try identity.publicKey.verifySignature(message: ecBytes, signature: ecSignature),
              try identity.publicKey.verifySignature(message: kemBytes, signature: kemSignature) else {
            throw ValidationError.invalidRegistrationKeys
        }
        return Snapshot(
            identity: identityBytes,
            registrationId: bigEndian(UInt32(material.registrationId)),
            ec: [bigEndian(UInt64(material.signedPreKey.keyId)), ecBytes, ecSignature],
            kem: [bigEndian(UInt64(material.lastResortPreKey.keyId)), kemBytes, kemSignature]
        )
    }

    private static func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
