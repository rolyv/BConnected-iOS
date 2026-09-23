// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Standalone simulator probe against the ACTUAL compiled framework, no AppDelegate/AppSetup.
// SQLCipher in-memory DB, real account/prekey stores. This is not device crash-durability or E2E proof.
import Foundation
import LibSignalClient
@testable import SignalServiceKit

enum Injected: Error { case rollback }
SetCurrentAppContext(TestAppContext(), isRunningTests: true)
let db = InMemoryDB()
let readiness = AppReadinessImpl()
let observer = DatabaseChangeObserverImpl(appReadiness: readiness)
func manager() -> TSAccountManagerImpl {
    TSAccountManagerImpl(appReadiness: readiness, dateProvider: { Date() }, databaseChangeObserver: observer, db: db)
}
let accountManager = manager()
var record = try BConnectedEnrollmentRecord.generate(.init(phone: "+13055550123", unidentifiedAccessKey: Data(repeating: 1, count: 16), apnsToken: nil, discoverableByPhoneNumber: false, signalAgent: "test", userAgent: "test original"))
record.binding = .init(memberId: "00000000-0000-4000-8000-000000000001", challenge: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
record.operationId = "00000000-0000-4000-8000-000000000010"
let account = BConnectedEnrollmentObservation.Account(aci: "00000000-0000-4000-8000-000000000011", pni: "00000000-0000-4000-8000-000000000012", number: record.phone, deviceId: 1)
let material = try BConnectedNativeAccountMaterial(record: record, account: account)
let preKeys = PreKeyStore()
let signedStore = SignedPreKeyStoreImpl(for: .aci, preKeyStore: preKeys)
let kyberStore = KyberPreKeyStoreImpl(for: .aci, dateProvider: { Date() }, preKeyStore: preKeys)
let signed = try LibSignalClient.SignedPreKeyRecord(bytes: record.aci.signedPreKey)
let kyber = try LibSignalClient.KyberPreKeyRecord(bytes: record.aci.lastResortPreKey)
let receipt = KeyValueStore(collection: "BConnectedEnrollment.v1")
record.installedAccount = account
try record.validate()
let frozen = try JSONEncoder().encode(record)
func hidden(_ manager: TSAccountManagerImpl, tx: DBReadTransaction) {
    precondition(manager.localIdentifiers(tx: tx) == nil)
    precondition(manager.storedServerAuthToken(tx: tx) == nil)
    precondition(manager.storedServerUsername(tx: tx) == nil)
    precondition(manager.registrationDate(tx: tx) == nil)
    guard case .unregistered = manager.registrationState(tx: tx) else { preconditionFailure("must remain unregistered") }
}
db.read { hidden(accountManager, tx: $0) } // Warm the cache before mutation.
do {
    try db.writeWithRollbackIfThrows { tx in
        try accountManager.validateBConnectedInstallation(material, repeated: false, tx: tx)
        let saveSigned = try signedStore.prepareBConnectedInitialKey(signed, tx: tx)
        let saveKyber = try kyberStore.prepareBConnectedInitialKey(kyber, tx: tx)
        accountManager.stageBConnectedInstallation(material, tx: tx)
        saveSigned(); saveKyber()
        receipt.setData(frozen, key: "attempt", transaction: tx)
        hidden(accountManager, tx: tx)
        hidden(manager(), tx: tx) // An initially empty cache must also hide an uncommitted install.
        throw Injected.rollback
    }
} catch Injected.rollback {}
try db.read { tx in
    hidden(accountManager, tx: tx)
    hidden(manager(), tx: tx)
    try accountManager.validateBConnectedInstallation(material, repeated: false, tx: tx)
    precondition(!preKeys.forIdentity(.aci).bconnectedHasAnyKeys(tx: tx))
    precondition(signedStore.getLastSuccessfulRotationDate(tx: tx) == nil)
    precondition(kyberStore.getLastSuccessfulRotationDate(tx: tx) == nil)
    precondition(receipt.getData("attempt", transaction: tx) == nil)
    precondition(accountManager.getRegistrationId(for: .aci, tx: tx) == nil)
}
print("PASS rollback clears account, key records, metadata and receipt; cached and fresh readers stay unregistered")
try db.writeWithRollbackIfThrows { tx in
    try accountManager.validateBConnectedInstallation(material, repeated: false, tx: tx)
    let saveSigned = try signedStore.prepareBConnectedInitialKey(signed, tx: tx)
    let saveKyber = try kyberStore.prepareBConnectedInitialKey(kyber, tx: tx)
    accountManager.stageBConnectedInstallation(material, tx: tx)
    saveSigned(); saveKyber()
    receipt.setData(frozen, key: "attempt", transaction: tx)
}
let restarted = manager()
try db.read { tx in
    hidden(accountManager, tx: tx)
    hidden(restarted, tx: tx)
    try restarted.validateBConnectedInstallation(material, repeated: true, tx: tx)
    precondition(receipt.getData("attempt", transaction: tx) == frozen)
    precondition(preKeys.forIdentity(.aci).fetchPreKey(in: .signed, for: signed.id, tx: tx)?.serializedRecord == record.aci.signedPreKey)
    precondition(preKeys.forIdentity(.aci).fetchPreKey(in: .kyber, for: kyber.id, tx: tx)?.serializedRecord == record.aci.lastResortPreKey)
    precondition(preKeys.forIdentity(.aci).fetchPreKey(in: .kyber, for: kyber.id, tx: tx)?.isOneTime == false)
    precondition(restarted.getRegistrationId(for: .aci, tx: tx) == material.registrationId)
    precondition(restarted.getRegistrationId(for: .pni, tx: tx) == material.pniRegistrationId)
}
print("PASS committed install survives manager recreation with exact bytes; credentials remain hidden")
var conflictRejected = false
let differentAccount = BConnectedEnrollmentObservation.Account(aci: "00000000-0000-4000-8000-000000000099", pni: account.pni, number: account.number, deviceId: 1)
let different = try BConnectedNativeAccountMaterial(record: record, account: differentAccount)
do { try db.writeWithRollbackIfThrows { try restarted.validateBConnectedInstallation(different, repeated: true, tx: $0) } }
catch BConnectedEnrollmentError.immutableConflict { conflictRejected = true }
precondition(conflictRejected)
db.read { precondition(receipt.getData("attempt", transaction: $0) == frozen) }
print("PASS conflicting server identity cannot replace staged account")
db.write { tx in
    precondition(signedStore.allocatePreKeyId(tx: tx) != signed.id)
    precondition(kyberStore.allocatePreKeyIds(count: 1, tx: tx).lowerBound != kyber.id)
}
print("PASS next key allocations preserve committed enrollment keys")

// This exercises only the final account-state primitive. The production coordinator must first
// obtain fresh status and account/profile readback and validate the full saved/native journal.
do {
    try db.writeWithRollbackIfThrows { tx in
        try accountManager.releaseBConnectedPendingServices(material, tx: tx)
        throw Injected.rollback
    }
} catch Injected.rollback {}
db.read { tx in
    hidden(accountManager, tx: tx)
    hidden(manager(), tx: tx)
    precondition(receipt.getData("attempt", transaction: tx) == frozen)
}
print("PASS rolled-back DM account release preserves pending barrier, credentials and journal")

try db.writeWithRollbackIfThrows { tx in
    try accountManager.releaseBConnectedPendingServices(material, tx: tx)
    precondition(receipt.getData("attempt", transaction: tx) == frozen)
}
accountManager.publishBConnectedRegistrationAfterCommit()
db.read { tx in
    for reader in [accountManager, manager()] {
        precondition(reader.registrationState(tx: tx).isRegisteredPrimaryDevice)
        precondition(reader.localIdentifiers(tx: tx)?.aci == material.aci)
        precondition(reader.storedServerAuthToken(tx: tx) == material.password)
        precondition(reader.registrationDate(tx: tx) != nil)
    }
    precondition(receipt.getData("attempt", transaction: tx) == frozen)
}
do {
    try db.writeWithRollbackIfThrows { try accountManager.releaseBConnectedPendingServices(material, tx: $0) }
    preconditionFailure("DM release repeated")
} catch BConnectedEnrollmentError.immutableConflict {}
print("PASS committed DM account release exposes exact saved primary credentials after cache refresh; no journal rewrite or repeat")
print("6 native database probes passed; no remote acceptance or device lifecycle effects")
