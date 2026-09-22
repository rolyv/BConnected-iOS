// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Actual local-setup transaction/recipient/profile storage. Native validator uses real TS account
// staging checks; private identity-manager lifecycle and file crash recovery remain separate tests.
import Foundation
import GRDB
import LibSignalClient
@testable import SignalServiceKit

enum Injected: Error { case rollback }
SetCurrentAppContext(TestAppContext(), isRunningTests: true)
struct Fixture {
    let db = InMemoryDB()
    let manager: TSAccountManagerImpl
    let record: BConnectedEnrollmentRecord
    let material: BConnectedNativeAccountMaterial
    let key = Aes256Key.generateRandom()
    init() throws {
        let readiness = AppReadinessImpl()
        manager = TSAccountManagerImpl(appReadiness: readiness, dateProvider: { Date() }, databaseChangeObserver: DatabaseChangeObserverImpl(appReadiness: readiness), db: db)
        var record = try BConnectedEnrollmentRecord.generate(.init(phone: "+13055550123", unidentifiedAccessKey: SMKUDAccessKey(profileKey: key).keyData,
            apnsToken: nil, discoverableByPhoneNumber: false, signalAgent: "test", userAgent: "test original"))
        record.binding = .init(memberId: "00000000-0000-4000-8000-000000000001", challenge: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
        record.operationId = "00000000-0000-4000-8000-000000000010"
        let account = BConnectedEnrollmentObservation.Account(aci: "00000000-0000-4000-8000-000000000011", pni: "00000000-0000-4000-8000-000000000012", number: record.phone, deviceId: 1)
        material = try .init(record: record, account: account)
        record.installedAccount = account
        self.record = record
        try db.writeWithRollbackIfThrows { tx in
            let profile = OWSUserProfile(address: .localUser, givenName: "Original", familyName: "Display Name", profileKey: key)
            // Synthetic preregistration fixture only: avoid application indexing/network observers.
            try tx.database.execute(sql: "INSERT INTO model_OWSUserProfile (recordType,uniqueId,recipientPhoneNumber,profileKey,profileName,familyName,profileBadgeInfo,isStoriesCapable,canReceiveGiftBadges,isPniCapable) VALUES (0,?,?,?,?,?,?,?,?,?)",
                arguments: [profile.uniqueId, profile.phoneNumber, key.keyData, "Original", "Display Name", Data("[]".utf8), true, true, true])
            try manager.validateBConnectedInstallation(material, repeated: false, tx: tx)
            manager.stageBConnectedInstallation(material, tx: tx)
            KeyValueStore(collection: "BConnectedEnrollment.v1").setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
        }
    }
    func validate(_ record: BConnectedEnrollmentRecord, _ account: BConnectedEnrollmentObservation.Account, _ tx: DBWriteTransaction) throws {
        try manager.validateBConnectedInstallation(try .init(record: record, account: account), repeated: true, tx: tx)
    }
    func prepare() throws { try BConnectedLocalAccountSetup.prepare(db: db, validateNative: validate) }
    func saved() throws -> BConnectedEnrollmentRecord { try db.read { try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: KeyValueStore(collection: "BConnectedEnrollment.v1").getData("attempt", transaction: $0)!) } }
    func changes() -> Int { db.read { try! Int.fetchOne($0.database, sql: "SELECT total_changes()")! } }
    func rowCount() -> Int { db.read { try! SignalRecipient.fetchCount($0.database) } }
    func unchangedProfileAndBarrier() {
        let readiness = AppReadinessImpl()
        let recreated = TSAccountManagerImpl(appReadiness: readiness, dateProvider: { Date() }, databaseChangeObserver: DatabaseChangeObserverImpl(appReadiness: readiness), db: db)
        db.read { tx in
            let profile = OWSUserProfile.getUserProfileForLocalUser(tx: tx)!
            precondition(profile.profileKey?.keyData == key.keyData && profile.givenName == "Original" && profile.familyName == "Display Name")
            precondition(manager.localIdentifiers(tx: tx) == nil && manager.storedServerAuthToken(tx: tx) == nil)
            for reader in [manager, recreated] {
                precondition(reader.localIdentifiers(tx: tx) == nil && reader.storedServerAuthToken(tx: tx) == nil)
                guard case .unregistered = reader.registrationState(tx: tx) else { preconditionFailure("readiness barrier released") }
            }
        }
    }
}
let first = try Fixture()
try first.prepare()
let installed = try first.saved()
precondition(installed.localSetupReceipt != nil && first.rowCount() == 1)
precondition(installed.password == first.record.password && installed.aci.pair == first.record.aci.pair && installed.registrationRequest == first.record.registrationRequest)
first.unchangedProfileAndBarrier()
let beforeRetry = first.changes()
try first.prepare()
// Recreate the actual persistence object. An unchanged progress transaction must not rewrite bytes.
let recreated = BConnectedEnrollmentStore(db: first.db)
_ = try recreated.transaction { $0?.localSetupReceipt }
precondition(first.changes() == beforeRetry)
let retried = try first.saved()
precondition(retried.localSetupReceipt == installed.localSetupReceipt)
print("PASS first self-recipient preparation and exact read-only retry/store recreation preserve profile, native material and barrier")

let rollback = try Fixture()
do {
    try rollback.db.writeWithRollbackIfThrows { tx in
        try BConnectedLocalAccountSetup.prepare(tx: tx, validateNative: rollback.validate)
        throw Injected.rollback
    }
} catch Injected.rollback {}
precondition(rollback.rowCount() == 0)
let rolledBack = try rollback.saved()
precondition(rolledBack.localSetupReceipt == nil)
rollback.unchangedProfileAndBarrier()
try rollback.prepare()
let afterRollbackRetry = try rollback.saved()
precondition(rollback.rowCount() == 1 && afterRollbackRetry.localSetupReceipt != nil)
print("PASS actual SQLCipher rollback removes both self-recipient and receipt; later retry succeeds")

for kind in 0..<6 {
    let conflict = try Fixture()
    try conflict.db.writeWithRollbackIfThrows { tx in
        switch kind {
        case 0: _ = try SignalRecipient.insertRecord(aci: conflict.material.aci, tx: tx)
        case 1: _ = try SignalRecipient.insertRecord(phoneNumber: E164(conflict.record.phone)!, tx: tx)
        case 2: _ = try SignalRecipient.insertRecord(pni: conflict.material.pni, tx: tx)
        case 3:
            _ = try SignalRecipient.insertRecord(aci: conflict.material.aci, tx: tx)
            _ = try SignalRecipient.insertRecord(pni: conflict.material.pni, tx: tx)
        case 4:
            _ = try SignalRecipient.insertRecord(aci: conflict.material.aci, tx: tx)
            _ = try SignalRecipient.insertRecord(pni: conflict.material.pni, tx: tx)
            _ = try SignalRecipient.insertRecord(phoneNumber: E164(conflict.record.phone)!, tx: tx)
        default:
            _ = try SignalRecipient.insertRecord(aci: conflict.material.aci, phoneNumber: E164(conflict.record.phone)!, pni: conflict.material.pni, tx: tx) // unregistered/partial device state
        }
    }
    let before = conflict.changes()
    do { try conflict.prepare(); preconditionFailure("partial/conflicting recipient accepted") }
    catch BConnectedEnrollmentError.immutableConflict {}
    precondition(conflict.changes() == before)
    let conflictingRecord = try conflict.saved()
    precondition(conflictingRecord.localSetupReceipt == nil)
}
print("PASS six partial/split identity and device conflicts fail before any mutation")

let blocked = try Fixture()
let blockIds = try blocked.db.writeWithRollbackIfThrows { tx in
    let own = try SignalRecipient.insertRecord(aci: blocked.material.aci, phoneNumber: E164(blocked.record.phone)!, pni: blocked.material.pni, deviceIds: [.primary], tx: tx)
    let other = try SignalRecipient.insertRecord(aci: Aci(fromUUID: UUID()), tx: tx)
    BlockedRecipientStore().setBlocked(true, recipientId: own.id, tx: tx)
    BlockedRecipientStore().setBlocked(true, recipientId: other.id, tx: tx)
    return [own.id, other.id].sorted()
}
let beforeBlock = blocked.changes()
do { try blocked.prepare(); preconditionFailure("blocked self accepted") }
catch BConnectedEnrollmentError.immutableConflict {}
precondition(blocked.changes() == beforeBlock)
blocked.db.read { precondition(BlockedRecipientStore().blockedRecipientIds(tx: $0).sorted() == blockIds) }
print("PASS blocked exact recipient is rejected and all existing blocks remain unchanged")

let reused = try Fixture()
let rowId = try reused.db.writeWithRollbackIfThrows { tx in
    try SignalRecipient.insertRecord(aci: reused.material.aci, phoneNumber: E164(reused.record.phone)!, pni: reused.material.pni, deviceIds: [.primary], tx: tx).id
}
try reused.prepare()
let reusedRecord = try reused.saved()
precondition(reused.rowCount() == 1 && reusedRecord.localSetupReceipt?.recipientId == rowId)
print("PASS an existing exact unblocked primary self-recipient is reused without duplication")

let changedProfile = try Fixture()
try changedProfile.db.writeWithRollbackIfThrows { tx in
    try tx.database.execute(sql: "UPDATE model_OWSUserProfile SET profileKey = ?", arguments: [Aes256Key.generateRandom().keyData])
}
let beforeProfile = changedProfile.changes()
do { try changedProfile.prepare(); preconditionFailure("changed profile key accepted") }
catch BConnectedEnrollmentError.immutableConflict {}
precondition(changedProfile.changes() == beforeProfile && changedProfile.rowCount() == 0)
print("PASS profile key mismatch is terminal before recipient or receipt mutation")
print("6 real local-setup database probe groups passed; no remote service or readiness effects")
