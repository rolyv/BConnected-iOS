// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import CryptoKit
import LibSignalClient

/// First-install self-recipient preparation only. No merging, profile mutation, caches, completion
/// callbacks, block clearing, storage service, networking, or registration-state publication.
enum BConnectedLocalAccountSetup {
    /// The same SQLCipher transaction checks the frozen journal before and after native validation.
    /// Only completed journals may enter the existing read-only native repeat paths.
    static func validateAccountAcceptance(configuration: BConnectedPublicationConfiguration,
        expected: BConnectedEnrollmentRecord?, tx: DBWriteTransaction,
        validateNative: () throws -> BConnectedEnrollmentRecord
    ) throws -> BConnectedEnrollmentRecord {
        let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
        guard let bytes = values.getData("attempt", transaction: tx) else { throw BConnectedEnrollmentError.missingAttempt }
        let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
        try original.validateAccountAcceptance(configuration: configuration, expected: expected)
        let validated = try validateNative()
        try validated.validateAccountAcceptance(configuration: configuration, expected: original)
        guard values.getData("attempt", transaction: tx) == bytes else { throw BConnectedEnrollmentError.immutableConflict }
        return validated
    }

    /// The caller revalidates native state in this same rollback-on-error transaction first.
    static func transitionPublication(record: BConnectedEnrollmentRecord, expected: BConnectedEnrollmentRecord,
        step: BConnectedPublicationStep, acknowledge: Bool, tx: DBWriteTransaction
    ) throws -> BConnectedEnrollmentRecord {
        var record = record
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
        guard let stored = values.getData("attempt", transaction: tx),
              try encoder.encode(JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: stored)) == encoder.encode(record),
              try encoder.encode(record) == encoder.encode(expected), var publication = record.publication,
              step != .profile || publication.attributesState == .acknowledged,
              publication.state(for: step) != .acknowledged,
              !acknowledge || publication.state(for: step) == .dispatched else { throw BConnectedEnrollmentError.immutableConflict }
        let next: BConnectedEnrollmentRecord.Publication.State = acknowledge ? .acknowledged : .dispatched
        if step == .attributes { publication.attributesState = next } else { publication.profileState = next }
        record.publication = publication; try record.validate()
        let bytes = try encoder.encode(record)
        if try bytes != encoder.encode(expected) { values.setData(bytes, key: "attempt", transaction: tx) }
        return record
    }

    static func preparePublication(tx: DBWriteTransaction, configuration: BConnectedPublicationConfiguration,
        accountKeyStore: AccountKeyStore, sharePhoneNumber: Bool,
        validateNative: (BConnectedEnrollmentRecord, BConnectedEnrollmentObservation.Account, DBWriteTransaction) throws -> Void
    ) throws -> BConnectedEnrollmentRecord {
        let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
        guard let bytes = values.getData("attempt", transaction: tx) else { throw BConnectedEnrollmentError.missingAttempt }
        var record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
        try record.validate()
        guard let entropy = record.accountEntropyReceipt, let account = record.installedAccount,
              record.observation?.state == .active, record.observation?.registrationAuthorized == true,
              record.observation?.account == account else { throw BConnectedEnrollmentError.immutableConflict }
        // Because an entropy receipt exists, this validates native, profile, recipient and key state
        // without generating keys or writing. Existing blocks and all unrelated state are preserved.
        try prepareAccountEntropy(tx: tx, accountKeyStore: accountKeyStore, validateNative: validateNative)
        guard let profile = OWSUserProfile.getUserProfileForLocalUser(tx: tx), let key = profile.profileKey else {
            throw BConnectedEnrollmentError.immutableConflict
        }
        let state: [String: Any] = ["key": key.keyData.base64EncodedString(), "given": profile.givenName as Any? ?? NSNull(),
            "family": profile.familyName as Any? ?? NSNull(), "bio": profile.bio as Any? ?? NSNull(),
            "emoji": profile.bioEmoji as Any? ?? NSNull(), "avatar": profile.avatarUrlPath as Any? ?? NSNull(), "sharePhone": sharePhoneNumber]
        let stateHash = Data(SHA256.hash(data: try BConnectedEnrollmentWire.encode(state)))
        if let publication = record.publication {
            guard publication.configurationHash == configuration.hash, publication.profileStateHash == stateHash else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            return record
        }
        let aci = Aci(fromUUID: UUID(uuidString: account.aci)!)
        let profileKey = try ProfileKey(contents: key.keyData)
        let given = profile.givenName.flatMap(OWSUserProfile.NameComponent.init(truncating:))
        let family = profile.familyName.flatMap(OWSUserProfile.NameComponent.init(truncating:))
        guard (profile.givenName == nil || given != nil), (family == nil || given != nil) else { throw BConnectedEnrollmentError.invalidInput }
        let name = try given.map { try OWSUserProfile.encrypt(givenName: $0, familyName: family, profileKey: key) }
        func encrypted(_ value: String?, lengths: [Int]) throws -> ProfileValue? {
            guard let value, !value.isEmpty else { return nil }
            return try OWSUserProfile.encrypt(data: Data(value.utf8), profileKey: key, paddedLengths: lengths)
        }
        let request = OWSRequestFactory.setVersionedProfileRequest(name: name,
            bio: try encrypted(profile.bio, lengths: [128, 254, 512]), bioEmoji: try encrypted(profile.bioEmoji, lengths: [32]),
            hasAvatar: true, sameAvatar: true, paymentAddress: nil,
            phoneNumberSharing: ProfileValue(encryptedData: try OWSUserProfile.encrypt(profileData: Data([sharePhoneNumber ? 1 : 0]), profileKey: key)),
            visibleBadgeIds: [], version: try profileKey.getProfileKeyVersion(userId: aci).asHexadecimalString(),
            commitment: try profileKey.getCommitment(userId: aci).serialize(), auth: .implicit())
        guard case .parameters(let parameters) = request.body else { throw BConnectedEnrollmentError.persistenceUnavailable }
        let encryptedProfile = try BConnectedEnrollmentWire.encode(parameters)
        let original = try BConnectedEnrollmentWire.object(record.registrationRequest)
        guard let attributes = original["accountAttributes"] as? [String: Any], attributes["recoveryPassword"] == nil,
              attributes["registrationLock"] == nil, attributes["name"] == nil else { throw BConnectedEnrollmentError.immutableConflict }
        let accountAttributes = try BConnectedEnrollmentWire.encode(attributes)
        record.publication = .init(version: 1, configurationHash: configuration.hash, entropyReceipt: entropy,
            profileStateHash: stateHash, accountAttributes: accountAttributes, encryptedProfile: encryptedProfile,
            payloadHash: BConnectedEnrollmentRecord.Publication.hash(attributes: accountAttributes, profile: encryptedProfile))
        try record.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        values.setData(try encoder.encode(record), key: "attempt", transaction: tx)
        return record
    }

    static func prepareAccountEntropy(
        tx: DBWriteTransaction,
        accountKeyStore: AccountKeyStore,
        validateNative: (BConnectedEnrollmentRecord, BConnectedEnrollmentObservation.Account, DBWriteTransaction) throws -> Void
    ) throws {
        let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
        var record: BConnectedEnrollmentRecord
        do {
            guard let bytes = values.getData("attempt", transaction: tx) else { throw BConnectedEnrollmentError.missingAttempt }
            record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
            try record.validate()
        } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
        guard let localSetup = record.localSetupReceipt else { throw BConnectedEnrollmentError.immutableConflict }
        // The existing receipt guarantees this is a validating, read-only retry. It rechecks
        // native material, profile/UAK, exact self-recipient identity and current blocks.
        try prepare(tx: tx, validateNative: validateNative)
        let entropy = try accountKeyStore.prepareBConnectedInitialEntropy(expectedHash: record.accountEntropyReceipt?.entropyHash, tx: tx)
        if record.accountEntropyReceipt != nil { return }
        record.accountEntropyReceipt = .init(version: 1, localSetup: localSetup, entropyHash: entropy.hash)
        try record.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(record)
        // Both native key and receipt writes belong to the caller's rollback-on-error transaction.
        // Nothing escapes via caches or completion callbacks, including after rollback.
        try entropy.install()
        values.setData(bytes, key: "attempt", transaction: tx)
    }

    static func prepare(
        db: any DB,
        validateNative: (BConnectedEnrollmentRecord, BConnectedEnrollmentObservation.Account, DBWriteTransaction) throws -> Void
    ) throws {
        try db.writeWithRollbackIfThrows { tx in
            try prepare(tx: tx, validateNative: validateNative)
        }
    }

    static func prepare(
        tx: DBWriteTransaction,
        validateNative: (BConnectedEnrollmentRecord, BConnectedEnrollmentObservation.Account, DBWriteTransaction) throws -> Void
    ) throws {
        let values = KeyValueStore(collection: "BConnectedEnrollment.v1")
        var record: BConnectedEnrollmentRecord
        do {
            guard let bytes = values.getData("attempt", transaction: tx) else { throw BConnectedEnrollmentError.missingAttempt }
            record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: bytes)
            try record.validate()
        } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
        guard let account = record.installedAccount else { throw BConnectedEnrollmentError.immutableConflict }
        try validateNative(record, account, tx)
        let material = try BConnectedNativeAccountMaterial(record: record, account: account)
        guard let profile = OWSUserProfile.getUserProfileForLocalUser(tx: tx), let key = profile.profileKey,
              SMKUDAccessKey(profileKey: key).keyData == material.unidentifiedAccessKey,
              let phone = E164(account.number) else { throw BConnectedEnrollmentError.immutableConflict }
        let hash = try record.profileAccessKeyHash()
        let candidates = try SignalRecipient.filter(
            Column(SignalRecipient.CodingKeys.aciString.rawValue) == material.aci.serviceIdUppercaseString
            || Column(SignalRecipient.CodingKeys.pni.rawValue) == material.pni.serviceIdUppercaseString
            || Column(SignalRecipient.CodingKeys.phoneNumber.rawValue) == account.number
        ).fetchAll(tx.database)
        guard candidates.count <= 1 else { throw BConnectedEnrollmentError.immutableConflict }
        let existing = candidates.first
        if let existing {
            guard existing.aci == material.aci, existing.pni == material.pni,
                  existing.phoneNumber?.stringValue == account.number, existing.deviceIds == [.primary],
                  existing.unregisteredAtTimestamp == nil,
                  !BlockedRecipientStore().isBlocked(recipientId: existing.id, tx: tx) else {
                throw BConnectedEnrollmentError.immutableConflict
            }
        }
        if let receipt = record.localSetupReceipt {
            guard let existing, receipt.recipientId == existing.id, receipt.recipientUniqueId == existing.uniqueId,
                  receipt.profileUniqueId == profile.uniqueId, receipt.profileAccessKeyHash == hash else {
                throw BConnectedEnrollmentError.immutableConflict
            }
            return // Exact retry is read-only, including the enrollment receipt.
        }
        // All conflicts/partial records have been rejected before this first possible write.
        // Raw GRDB insertion has no merge observers or caches. If receipt encoding/write fails,
        // rollback removes the inserted row as well; no object escapes the transaction.
        let recipient = try existing ?? SignalRecipient.insertRecord(
            aci: material.aci, phoneNumber: phone, pni: material.pni, deviceIds: [.primary], tx: tx
        )
        record.localSetupReceipt = .init(version: 1, attempt: record.attempt, keyCommitment: record.keyCommitment,
            account: account, profileUniqueId: profile.uniqueId, profileAccessKeyHash: hash,
            recipientId: recipient.id, recipientUniqueId: recipient.uniqueId)
        let encoded: Data
        do {
            try record.validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            encoded = try encoder.encode(record)
        } catch { throw BConnectedEnrollmentError.persistenceUnavailable }
        values.setData(encoded, key: "attempt", transaction: tx)
    }
}
