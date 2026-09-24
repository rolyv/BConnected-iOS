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

func entropy(_ fixture: Fixture) throws {
    try fixture.db.writeWithRollbackIfThrows { tx in
        try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx,
            accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), validateNative: fixture.validate)
        precondition(tx.completionBlocks.isEmpty, "entropy setup must not schedule logging/lifecycle effects")
    }
}
func entropyKey(_ fixture: Fixture) -> String? {
    fixture.db.read { NewKeyValueStore(collection: "AccountEntropyPool").fetchValue(String.self, forKey: "aep", tx: $0) }
}
let entropyFirst = try Fixture()
let beforeMissingLocal = entropyFirst.changes()
do { try entropy(entropyFirst); preconditionFailure("entropy accepted before local setup") }
catch BConnectedEnrollmentError.immutableConflict {}
precondition(entropyFirst.changes() == beforeMissingLocal && entropyKey(entropyFirst) == nil)
try entropyFirst.prepare()
try entropy(entropyFirst)
let savedEntropy = try entropyFirst.saved().accountEntropyReceipt!
let savedKey = entropyKey(entropyFirst)!
precondition(LibSignalClient.AccountEntropyPool.isValid(savedKey) && savedEntropy.entropyHash.count == 32)
let beforeEntropyRetry = entropyFirst.changes()
try entropy(entropyFirst) // Constructs a new AccountKeyStore; reads the committed key and receipt.
precondition(entropyFirst.changes() == beforeEntropyRetry && entropyKey(entropyFirst) == savedKey)
let repeatedEntropy = try entropyFirst.saved().accountEntropyReceipt
precondition(repeatedEntropy == savedEntropy)
entropyFirst.unchangedProfileAndBarrier()
print("PASS entropy requires local setup; first write and read-only retry preserve original keys/profile and pending-services with no completion callbacks")

let entropyRollback = try Fixture()
try entropyRollback.prepare()
do {
    try entropyRollback.db.writeWithRollbackIfThrows { tx in
        try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx,
            accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), validateNative: entropyRollback.validate)
        precondition(tx.completionBlocks.isEmpty)
        throw Injected.rollback
    }
} catch Injected.rollback {}
let rolledBackEntropy = try entropyRollback.saved().accountEntropyReceipt
precondition(rolledBackEntropy == nil && entropyKey(entropyRollback) == nil)
try entropy(entropyRollback)
entropyRollback.unchangedProfileAndBarrier()
print("PASS rollback removes native entropy and its receipt together; a later first-install retry succeeds")

for kind in 0..<7 {
    let conflict = try Fixture()
    try conflict.prepare()
    conflict.db.write { tx in
        switch kind {
        case 0: NewKeyValueStore(collection: "AccountEntropyPool").writeValue(LibSignalClient.AccountEntropyPool.generate(), forKey: "aep", tx: tx)
        case 1: NewKeyValueStore(collection: "AccountEntropyPool").writeValue("malformed", forKey: "aep", tx: tx)
        case 2: NewKeyValueStore(collection: "AccountEntropyPool").writeValue(Data([1]), forKey: "unknown", tx: tx)
        case 3: NewKeyValueStore(collection: "MediaRootBackupKey").writeValue(Data(repeating: 1, count: 32), forKey: "mrbk", tx: tx)
        case 4: NewKeyValueStore(collection: "AccountKey.Sync").writeValue(true, forKey: "isWaitingForKeysSync", tx: tx)
        case 5: NewKeyValueStore(collection: "BackupSettingsStore").writeValue(Data([1]), forKey: "unknown", tx: tx)
        default: NewKeyValueStore(collection: "LocalFileBackups").writeValue(true, forKey: "isEnabledKey", tx: tx)
        }
    }
    let before = conflict.changes()
    do { try entropy(conflict); preconditionFailure("foreign/partial entropy or backup state accepted") }
    catch BConnectedEnrollmentError.immutableConflict {}
    precondition(conflict.changes() == before)
    let rejected = try conflict.saved().accountEntropyReceipt
    precondition(rejected == nil)
}
print("PASS seven foreign/malformed/partial entropy, backup and sync states reject before mutation")

for replace in [false, true] {
    let changed = try Fixture()
    try changed.prepare(); try entropy(changed)
    changed.db.write { tx in
        let store = NewKeyValueStore(collection: "AccountEntropyPool")
        if replace { store.writeValue(LibSignalClient.AccountEntropyPool.generate(), forKey: "aep", tx: tx) }
        else { store.removeValue(forKey: "aep", tx: tx) }
    }
    let before = changed.changes()
    do { try entropy(changed); preconditionFailure("missing/changed committed entropy accepted") }
    catch BConnectedEnrollmentError.immutableConflict {}
    precondition(changed.changes() == before)
}
print("PASS missing or changed committed entropy cannot be regenerated or accepted on retry")

let blockedEntropy = try Fixture()
try blockedEntropy.prepare()
let blockedId = try blockedEntropy.saved().localSetupReceipt!.recipientId
blockedEntropy.db.write { BlockedRecipientStore().setBlocked(true, recipientId: blockedId, tx: $0) }
let beforeBlockedEntropy = blockedEntropy.changes()
do { try entropy(blockedEntropy); preconditionFailure("entropy accepted after self-recipient block") }
catch BConnectedEnrollmentError.immutableConflict {}
precondition(blockedEntropy.changes() == beforeBlockedEntropy && entropyKey(blockedEntropy) == nil)
print("PASS entropy setup revalidates the prior self-recipient receipt and preserves current blocks")

var invalidEntropy = try entropyFirst.saved()
invalidEntropy.accountEntropyReceipt = .init(version: 1, localSetup: savedEntropy.localSetup, entropyHash: Data([1]))
do { try invalidEntropy.validate(); preconditionFailure("invalid entropy receipt accepted") }
catch BConnectedEnrollmentError.persistenceUnavailable {}
invalidEntropy = try entropyFirst.saved(); invalidEntropy.localSetupReceipt = nil
do { try invalidEntropy.validate(); preconditionFailure("unbound entropy receipt accepted") }
catch BConnectedEnrollmentError.persistenceUnavailable {}
print("PASS malformed or unbound entropy receipt fails persisted-state validation")

func check(_ condition: Bool) { precondition(condition) }

func activate(_ fixture: Fixture) throws {
    try fixture.db.writeWithRollbackIfThrows { tx in
        var record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: KeyValueStore(collection: "BConnectedEnrollment.v1").getData("attempt", transaction: tx)!)
        record.observation = .init(operationId: record.operationId!, state: .active, registrationAuthorized: true,
            phoneVerified: true, nextSmsSeconds: nil, nextCheckSeconds: nil, expiresInSeconds: nil, account: record.installedAccount)
        KeyValueStore(collection: "BConnectedEnrollment.v1").setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
    }
}
let publicationConfiguration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
func publication(_ fixture: Fixture, tx: DBWriteTransaction, configuration: BConnectedPublicationConfiguration = publicationConfiguration) throws -> BConnectedEnrollmentRecord {
    let record = try BConnectedLocalAccountSetup.preparePublication(tx: tx, configuration: configuration,
        accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), sharePhoneNumber: false, validateNative: fixture.validate)
    check(tx.completionBlocks.isEmpty)
    return record
}
func publication(_ fixture: Fixture) throws -> BConnectedEnrollmentRecord {
    try fixture.db.writeWithRollbackIfThrows { try publication(fixture, tx: $0) }
}
func transition(_ fixture: Fixture, expected: BConnectedEnrollmentRecord, step: BConnectedPublicationStep, ack: Bool, rollback: Bool = false) throws -> BConnectedEnrollmentRecord {
    try fixture.db.writeWithRollbackIfThrows { tx in
        let current = try publication(fixture, tx: tx)
        let next = try BConnectedLocalAccountSetup.transitionPublication(record: current, expected: expected, step: step, acknowledge: ack, tx: tx)
        check(tx.completionBlocks.isEmpty)
        if rollback { throw Injected.rollback }
        return next
    }
}
let publishing = try Fixture()
try publishing.prepare(); try activate(publishing)
let beforeMissingEntropy = publishing.changes()
do { _ = try publication(publishing); preconditionFailure("publication accepted without entropy receipt") }
catch BConnectedEnrollmentError.immutableConflict {}
check(publishing.changes() == beforeMissingEntropy)
try entropy(publishing)
do {
    _ = try publishing.db.writeWithRollbackIfThrows { tx in
        _ = try publication(publishing, tx: tx)
        throw Injected.rollback
    }
} catch Injected.rollback {}
try check(publishing.saved().publication == nil)
let prepared = try publication(publishing)
let payload = prepared.publication!
let object = try BConnectedEnrollmentWire.object(payload.encryptedProfile)
let nativeKey = try ProfileKey(contents: publishing.key.keyData)
let decrypted = try OWSUserProfile.decrypt(profileNameData: Data(base64Encoded: object["name"] as! String)!, profileKey: nativeKey)
check(decrypted.givenName == "Original" && decrypted.familyName == "Display Name")
try check(!OWSUserProfile.decrypt(profileBooleanData: Data(base64Encoded: object["phoneNumberSharing"] as! String)!, profileKey: nativeKey))
check(object["commitment"] as? String == (try nativeKey.getCommitment(userId: publishing.material.aci).serialize().base64EncodedString()))
check(object["version"] as? String == (try nativeKey.getProfileKeyVersion(userId: publishing.material.aci).asHexadecimalString()))
let attrs = try BConnectedEnrollmentWire.object(payload.accountAttributes)
check(attrs["recoveryPassword"] == nil && attrs["registrationLock"] == nil && attrs["name"] == nil)
check(attrs["unidentifiedAccessKey"] as? String == SMKUDAccessKey(profileKey: publishing.key).keyData.base64EncodedString())
let beforePublicationRetry = publishing.changes()
let repeatPublication = try publication(publishing)
check(repeatPublication.publication == payload && publishing.changes() == beforePublicationRetry)
publishing.unchangedProfileAndBarrier()
print("PASS actual native profile encryption/commitment and frozen attributes require entropy; draft rollback is atomic and exact retry is read-only with no callbacks")

do { _ = try transition(publishing, expected: prepared, step: .profile, ack: false); preconditionFailure("out-of-order profile dispatch accepted") }
catch BConnectedEnrollmentError.immutableConflict {}
do { _ = try transition(publishing, expected: prepared, step: .attributes, ack: true); preconditionFailure("ack before dispatch accepted") }
catch BConnectedEnrollmentError.immutableConflict {}
do { _ = try transition(publishing, expected: prepared, step: .attributes, ack: false, rollback: true) }
catch Injected.rollback {}
try check(publishing.saved().publication == payload)
let dispatched = try transition(publishing, expected: prepared, step: .attributes, ack: false)
do { _ = try transition(publishing, expected: prepared, step: .attributes, ack: true); preconditionFailure("stale expected record accepted") }
catch BConnectedEnrollmentError.immutableConflict {}
do { _ = try transition(publishing, expected: dispatched, step: .attributes, ack: true, rollback: true) }
catch Injected.rollback {}
try check(publishing.saved().publication?.attributesState == .dispatched)
let beforeReplay = publishing.changes()
let replay = try transition(publishing, expected: dispatched, step: .attributes, ack: false)
check(publishing.changes() == beforeReplay && replay.publication == dispatched.publication)
let attributesAccepted = try transition(publishing, expected: replay, step: .attributes, ack: true)
let profileDispatched = try transition(publishing, expected: attributesAccepted, step: .profile, ack: false)
let complete = try transition(publishing, expected: profileDispatched, step: .profile, ack: true)
check(complete.publication!.complete && complete.publication!.encryptedProfile == payload.encryptedProfile)
publishing.unchangedProfileAndBarrier()
print("PASS SQLCipher publication sequence, stale snapshot checks, dispatch/ack rollback and read-only replay preserve frozen bytes and keep readiness hidden")

for kind in 0..<4 {
    let fixture = try Fixture(); try fixture.prepare(); try entropy(fixture); try activate(fixture)
    _ = try publication(fixture)
    if kind == 0 {
        fixture.db.write { try! $0.database.execute(sql: "UPDATE model_OWSUserProfile SET profileName = 'Changed'") }
    } else if kind == 1 {
        let id = try fixture.saved().localSetupReceipt!.recipientId
        fixture.db.write { BlockedRecipientStore().setBlocked(true, recipientId: id, tx: $0) }
    } else if kind == 2 {
        fixture.db.write { NewKeyValueStore(collection: "AccountEntropyPool").writeValue(LibSignalClient.AccountEntropyPool.generate(), forKey: "aep", tx: $0) }
    }
    let before = fixture.changes()
    do {
        _ = try fixture.db.writeWithRollbackIfThrows { tx in
            let configuration = kind == 3 ? try BConnectedPublicationConfiguration(origin: publicationConfiguration.origin, authorityCommitment: Data(repeating: 2, count: 32)) : publicationConfiguration
            return try publication(fixture, tx: tx, configuration: configuration)
        }
        preconditionFailure("changed publication prerequisite accepted")
    } catch BConnectedEnrollmentError.immutableConflict {}
    check(fixture.changes() == before)
}
print("PASS changed profile, block, native entropy and authority configuration all reject publication before mutation")

// The submitted full name must survive into the first encrypted profile without splitting,
// and rollback/retry must preserve the original profile and frozen publication bytes.
func saveSignup(_ fixture: Fixture, name: String = "José María 李",
                mutate: (inout BConnectedCommunityRecord) -> Void = { _ in }) throws {
    let account = try fixture.saved()
    try fixture.db.writeWithRollbackIfThrows { tx in
        let applicationId = "00000000-0000-4000-8000-000000000077"
        let nonce = BConnectedEnrollmentWire.base64url(Data(repeating: 7, count: 32))
        var community = BConnectedCommunityRecord()
        community.applicationDispatched = true
        community.phoneApplication = .init(phone: account.phone, fullName: name, graduationYear: 2008,
            nonce: nonce, createdAtMillis: nil)
        community.phoneChallenge = .init(applicationId: applicationId, expiresAt: 1_900_000_000_000)
        community.phoneSignup = .init(operationId: applicationId,
            observation: .init(operationId: applicationId, phoneVerified: true, nextSmsSeconds: nil, nextCheckSeconds: nil, expiresInSeconds: 600))
        community.session = .init(token: nonce, expiresAt: 1_900_000_000_000,
            member: .init(id: account.binding!.memberId, fullName: name, graduationYear: 2008, status: .approved))
        community.binding = .init(memberId: account.binding!.memberId,
            bindingChallenge: account.binding!.challenge, expiresAt: 1_900_000_000_000)
        mutate(&community)
        try community.validate()
        KeyValueStore(collection: "BConnectedCommunityEnrollment.v1").setData(try JSONEncoder().encode(community), key: "session", transaction: tx)
    }
}

let signupName = try Fixture()
try signupName.prepare(); try activate(signupName); try entropy(signupName)
try saveSignup(signupName)
do {
    _ = try signupName.db.writeWithRollbackIfThrows { tx in
        _ = try publication(signupName, tx: tx)
        throw Injected.rollback
    }
} catch Injected.rollback {}
signupName.db.read { tx in
    check(OWSUserProfile.getUserProfileForLocalUser(tx: tx)?.givenName == "Original")
}
let namePublication = try publication(signupName)
let namePayload = try BConnectedEnrollmentWire.object(namePublication.publication!.encryptedProfile)
let nameKey = try ProfileKey(contents: signupName.key.keyData)
let displayName = try OWSUserProfile.decrypt(profileNameData: Data(base64Encoded: namePayload["name"] as! String)!, profileKey: nameKey)
check(displayName.givenName == "José María 李" && displayName.familyName == nil)
let nameChanges = signupName.changes()
try check(publication(signupName).publication == namePublication.publication)
check(signupName.changes() == nameChanges)
print("PASS signup full name seeds the first encrypted profile without splitting; rollback and exact replay preserve native state and payload")

for kind in 0..<5 {
    let fixture = try Fixture(); try fixture.prepare(); try activate(fixture); try entropy(fixture)
    try saveSignup(fixture) { community in
        switch kind {
        case 0: community.session = nil; community.binding = nil
        case 1: community.binding = nil
        case 2:
            let otherId = "00000000-0000-4000-8000-000000000099"
            community.session!.member = .init(id: otherId, fullName: "José María 李", graduationYear: 2008, status: .approved)
            community.binding = .init(memberId: otherId, bindingChallenge: community.binding!.bindingChallenge, expiresAt: 1_900_000_000_000)
        case 3:
            community.binding = .init(memberId: community.binding!.memberId,
                bindingChallenge: BConnectedEnrollmentWire.base64url(Data(repeating: 9, count: 32)), expiresAt: 1_900_000_000_000)
        default:
            community.session!.member = .init(id: community.session!.member.id, fullName: "José María 李", graduationYear: 2008, status: .suspended)
        }
    }
    let before = fixture.changes()
    do { _ = try publication(fixture); preconditionFailure("unbound or unapproved signup name accepted") }
    catch BConnectedEnrollmentError.immutableConflict {}
    check(fixture.changes() == before)
    try check(fixture.saved().publication == nil)
    fixture.unchangedProfileAndBarrier()
}
print("PASS missing, mismatched and suspended community bindings reject signup profile seeding before mutation")

for name in [String(repeating: "A", count: 26), "李", "محمد", String(repeating: "👩🏽‍🚀", count: 8)] {
    let fixture = try Fixture(); try fixture.prepare(); try activate(fixture); try entropy(fixture)
    try saveSignup(fixture, name: name)
    let saved = try publication(fixture)
    let payload = try BConnectedEnrollmentWire.object(saved.publication!.encryptedProfile)
    let decrypted = try OWSUserProfile.decrypt(profileNameData: Data(base64Encoded: payload["name"] as! String)!,
        profileKey: ProfileKey(contents: fixture.key.keyData))
    check(decrypted.givenName == name && decrypted.familyName == nil)
}
for name in [String(repeating: "A", count: 27), String(repeating: "👩🏽‍🚀", count: 9)] {
    let fixture = try Fixture(); try fixture.prepare(); try activate(fixture); try entropy(fixture)
    try saveSignup(fixture, name: name)
    let before = fixture.changes()
    do { _ = try publication(fixture); preconditionFailure("incompatible signup name was truncated") }
    catch BConnectedEnrollmentError.immutableConflict {}
    check(fixture.changes() == before)
    try check(fixture.saved().publication == nil)
    fixture.unchangedProfileAndBarrier()
}
print("PASS complete Unicode and boundary-length signup names round-trip while oversized names reject without truncation")

for (caseIndex, (given, family)) in [(String(repeating: "A", count: 27), "Family"),
                                   ("Given", String(repeating: "B", count: 27)),
                                   ("Given", " ")].enumerated() {
    let fixture = try Fixture(); try fixture.prepare(); try activate(fixture); try entropy(fixture)
    try fixture.db.writeWithRollbackIfThrows { tx in
        try tx.database.execute(sql: "UPDATE model_OWSUserProfile SET profileName = ?, familyName = ?", arguments: [given, family])
    }
    let before = fixture.changes()
    do { _ = try publication(fixture); preconditionFailure("mismatched encrypted profile name case \(caseIndex) was frozen") }
    catch BConnectedEnrollmentError.invalidInput {}
    check(fixture.changes() == before)
    try check(fixture.saved().publication == nil)
}
print("PASS first native publication rejects truncated and empty name components without freezing mismatched bytes")

print("19 real local-account/entropy/publication database probe groups passed; no remote service or readiness effects")
