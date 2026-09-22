// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB

/// First-install self-recipient preparation only. No merging, profile mutation, caches, completion
/// callbacks, block clearing, storage service, networking, or registration-state publication.
enum BConnectedLocalAccountSetup {
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
