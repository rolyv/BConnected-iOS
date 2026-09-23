// Copyright 2026 BConnected contributors. SPDX-License-Identifier: AGPL-3.0-only
// Separate simulator processes, actual SQLCipher/WAL and production account/prekey/local-setup
// methods. Not AppSetup, full native identity-manager installation, Keychain or device power loss.
import Darwin
import Foundation
import GRDB
import LibSignalClient
@testable import SignalServiceKit

func check(_ condition: Bool) { precondition(condition) }
SetCurrentAppContext(TestAppContext(), isRunningTests: true)
precondition(CommandLine.arguments.count == 4)
let mode = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
var key = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
precondition(key.count == 48)
if mode == "wrong-key" { key[0] ^= 1 }
let keyFetcher = GRDBKeyFetcher(keychainStorage: MockKeychainStorage())
try keyFetcher.store(data: key)
var configuration = GRDB.Configuration()
configuration.acceptsDoubleQuotedStringLiterals = true
configuration.defaultTransactionKind = .immediate
configuration.prepareDatabase { try GRDBDatabaseStorageAdapter.prepareDatabase(db: $0, keyFetcher: keyFetcher) }
if mode == "wrong-key" {
    do {
        let candidate = try DatabasePool(path: path, configuration: configuration)
        _ = try candidate.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sqlite_master") }
        preconditionFailure("encrypted database accepted wrong key")
    } catch {
        print("PASS encrypted-file schema cannot be read with a different key")
        exit(0)
    }
}
let database = try DatabasePool(path: path, configuration: configuration)
if mode == "initialize" { try GRDBSchemaMigrator.runIncrementalMigrations(databaseWriter: database) }
try database.read {
    try check(String.fetchOne($0, sql: "PRAGMA journal_mode") == "wal")
    try check(String.fetchOne($0, sql: "PRAGMA integrity_check") == "ok")
    try check(String.fetchAll($0, sql: "PRAGMA cipher_integrity_check").isEmpty)
}
let readiness = AppReadinessImpl()
// The production operations below always receive the file's explicit transaction. This unused
// dependency prevents any unrelated app lifecycle/DB startup from participating in the probe.
let manager = TSAccountManagerImpl(appReadiness: readiness, dateProvider: { Date() },
    databaseChangeObserver: DatabaseChangeObserverImpl(appReadiness: readiness), db: InMemoryDB())
let enrollment = KeyValueStore(collection: "BConnectedEnrollment.v1")
let evidence = KeyValueStore(collection: "BConnectedFileProbe.v1")
let preKeys = PreKeyStore()
func readRecord(_ tx: DBReadTransaction) throws -> BConnectedEnrollmentRecord {
    let record = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: enrollment.getData("attempt", transaction: tx)!)
    try record.validate()
    return record
}
func hidden(_ tx: DBReadTransaction) {
    precondition(manager.localIdentifiers(tx: tx) == nil && manager.storedServerAuthToken(tx: tx) == nil)
    precondition(manager.storedServerUsername(tx: tx) == nil && manager.registrationDate(tx: tx) == nil)
    guard case .unregistered = manager.registrationState(tx: tx) else { preconditionFailure("services barrier released") }
}
func crash() -> Never {
    // Marker distinguishes the intended kill point from launch/link/migration/assertion failures.
    try! Data(mode.utf8).write(to: URL(fileURLWithPath: path + ".kill-point"), options: .atomic)
    kill(getpid(), SIGKILL)
    fatalError("SIGKILL returned")
}
func write(_ block: (DBWriteTransaction) throws -> Void) throws {
    try database.write { native in
        let tx = DBWriteTransaction(database: native)
        defer { tx.finalizeTransaction() }
        try block(tx)
        precondition(tx.completionBlocks.isEmpty, "probe must not enqueue lifecycle callbacks")
    }
}
func account(for record: BConnectedEnrollmentRecord) -> BConnectedEnrollmentObservation.Account {
    .init(aci: "00000000-0000-4000-8000-000000000011", pni: "00000000-0000-4000-8000-000000000012", number: record.phone, deviceId: 1)
}
func validate(_ record: BConnectedEnrollmentRecord, _ account: BConnectedEnrollmentObservation.Account, _ tx: DBWriteTransaction) throws {
    try manager.validateBConnectedInstallation(.init(record: record, account: account), repeated: true, tx: tx)
}

let publicationConfiguration = try BConnectedPublicationConfiguration(origin: URL(string: "https://publication.example.invalid")!, authorityCommitment: Data(repeating: 1, count: 32))
func publication(_ tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
    try BConnectedLocalAccountSetup.preparePublication(tx: tx, configuration: publicationConfiguration,
        accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), sharePhoneNumber: false, validateNative: validate)
}

func preparePreKeys(_ tx: DBWriteTransaction) throws -> BConnectedEnrollmentRecord {
    try BConnectedPreKeySetup.prepare(record: publication(tx), preKeyStore: preKeys, tx: tx)
}
func counters(_ tx: DBReadTransaction) throws -> Data {
    var values: [String: Any] = [:]
    for (name, identity) in [("aci", OWSIdentity.aci), ("pni", .pni)] {
        values[name + "EC"] = PreKeyStoreImpl(for: identity, preKeyStore: preKeys).bconnectedLastAllocatedId(tx: tx) as Any? ?? NSNull()
        values[name + "PQ"] = KyberPreKeyStoreImpl(for: identity, dateProvider: { Date() }, preKeyStore: preKeys).bconnectedLastAllocatedId(tx: tx) as Any? ?? NSNull()
    }
    return try BConnectedEnrollmentWire.encode(values)
}

switch mode {
case "initialize":
    let profileKey = Aes256Key.generateRandom()
    var record = try BConnectedEnrollmentRecord.generate(.init(phone: "+13055550123",
        unidentifiedAccessKey: SMKUDAccessKey(profileKey: profileKey).keyData, apnsToken: nil,
        discoverableByPhoneNumber: false, signalAgent: "test", userAgent: "file recovery probe"))
    record.binding = .init(memberId: "00000000-0000-4000-8000-000000000001", challenge: "ICEiIyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8")
    record.operationId = "00000000-0000-4000-8000-000000000010"
    let original = try JSONEncoder().encode(record)
    try write { tx in
        let profile = OWSUserProfile(address: .localUser, givenName: "Original", familyName: "Display Name", profileKey: profileKey)
        try tx.database.execute(sql: "INSERT INTO model_OWSUserProfile (recordType,uniqueId,recipientPhoneNumber,profileKey,profileName,familyName,profileBadgeInfo,isStoriesCapable,canReceiveGiftBadges,isPniCapable) VALUES (0,?,?,?,?,?,?,?,?,?)",
            arguments: [profile.uniqueId, profile.phoneNumber, profileKey.keyData, "Original", "Display Name", Data("[]".utf8), true, true, true])
        enrollment.setData(original, key: "attempt", transaction: tx)
        evidence.setData(original, key: "original", transaction: tx)
        evidence.setData(profileKey.keyData, key: "profile-key", transaction: tx)
    }
    print("PASS durable preregistration fixture committed to encrypted SQLCipher/WAL")
case "install-crash", "install-commit-crash":
    try write { tx in
        hidden(tx) // Warm the account cache before staging.
        var record = try readRecord(tx)
        let installed = account(for: record)
        let material = try BConnectedNativeAccountMaterial(record: record, account: installed)
        try manager.validateBConnectedInstallation(material, repeated: false, tx: tx)
        for (identity, saved) in [(OWSIdentity.aci, record.aci), (OWSIdentity.pni, record.pni)] {
            try SignedPreKeyStoreImpl(for: identity, preKeyStore: preKeys).prepareBConnectedInitialKey(
                LibSignalClient.SignedPreKeyRecord(bytes: saved.signedPreKey), tx: tx)()
            try KyberPreKeyStoreImpl(for: identity, dateProvider: { Date() }, preKeyStore: preKeys).prepareBConnectedInitialKey(
                LibSignalClient.KyberPreKeyRecord(bytes: saved.lastResortPreKey), tx: tx)()
        }
        manager.stageBConnectedInstallation(material, tx: tx)
        record.installedAccount = installed
        try record.validate()
        enrollment.setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
        hidden(tx)
        if mode == "install-crash" { crash() }
    }
    crash() // Committed WAL; deliberately no normal DB close/checkpoint.
case "verify-uninstalled", "verify-installed", "verify-local", "retry-local", "verify-entropy", "retry-entropy":
    try database.read { native in
        let tx = DBReadTransaction(database: native)
        hidden(tx)
        let record = try readRecord(tx)
        let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: evidence.getData("original", transaction: tx)!)
        precondition(record.password == original.password && record.aci.pair == original.aci.pair && record.pni.pair == original.pni.pair)
        precondition(record.registrationRequest == original.registrationRequest && record.attempt == original.attempt && record.keyCommitment == original.keyCommitment)
        let profile = OWSUserProfile.getUserProfileForLocalUser(tx: tx)!
        precondition(profile.profileKey!.keyData == evidence.getData("profile-key", transaction: tx))
        precondition(profile.givenName == "Original" && profile.familyName == "Display Name")
        let installed = mode != "verify-uninstalled"
        precondition((record.installedAccount != nil) == installed)
        try manager.validateBConnectedInstallation(.init(record: record, account: account(for: record)), repeated: installed, tx: tx)
        for (identity, saved) in [(OWSIdentity.aci, record.aci), (OWSIdentity.pni, record.pni)] {
            if installed {
                let signed = try LibSignalClient.SignedPreKeyRecord(bytes: saved.signedPreKey)
                let kyber = try LibSignalClient.KyberPreKeyRecord(bytes: saved.lastResortPreKey)
                precondition(preKeys.forIdentity(identity).fetchPreKey(in: .signed, for: signed.id, tx: tx)?.serializedRecord == saved.signedPreKey)
                precondition(preKeys.forIdentity(identity).fetchPreKey(in: .kyber, for: kyber.id, tx: tx)?.serializedRecord == saved.lastResortPreKey)
            } else { precondition(!preKeys.forIdentity(identity).bconnectedHasAnyKeys(tx: tx)) }
        }
        let hasEntropy = mode == "verify-entropy" || mode == "retry-entropy"
        let local = mode == "verify-local" || mode == "retry-local" || hasEntropy
        precondition((record.localSetupReceipt != nil) == local)
        precondition((record.accountEntropyReceipt != nil) == hasEntropy)
        let entropy = NewKeyValueStore(collection: "AccountEntropyPool").fetchValue(String.self, forKey: "aep", tx: tx)
        precondition((entropy != nil) == hasEntropy)
        if let entropy { precondition(LibSignalClient.AccountEntropyPool.isValid(entropy)) }
        try check(SignalRecipient.fetchCount(native) == (local ? 1 : 0))
    }
    if mode == "retry-local" || mode == "retry-entropy" || mode == "verify-entropy" {
        try write { tx in
            let before = try Int.fetchOne(tx.database, sql: "SELECT total_changes()")!
            let bytes = enrollment.getData("attempt", transaction: tx)
            if mode == "retry-local" {
                try BConnectedLocalAccountSetup.prepare(tx: tx, validateNative: validate)
            } else {
                try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx,
                    accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), validateNative: validate)
            }
            try check(Int.fetchOne(tx.database, sql: "SELECT total_changes()") == before)
            precondition(enrollment.getData("attempt", transaction: tx) == bytes)
        }
    }
    print("PASS \(mode) in a fresh process: original bytes/profile/keys and pending-services barrier preserved")
case "local-crash", "local-commit-crash":
    try write { tx in
        try BConnectedLocalAccountSetup.prepare(tx: tx, validateNative: validate)
        try check(SignalRecipient.fetchCount(tx.database) == 1)
        try check(readRecord(tx).localSetupReceipt != nil)
        if mode == "local-crash" { crash() }
    }
    crash()
case "entropy-crash", "entropy-commit-crash":
    try write { tx in
        try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx,
            accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), validateNative: validate)
        try check(readRecord(tx).accountEntropyReceipt != nil)
        if mode == "entropy-crash" { crash() }
    }
    crash()
case "publication-crash", "publication-commit-crash":
    try write { tx in
        var record = try readRecord(tx)
        record.observation = .init(operationId: record.operationId!, state: .active, registrationAuthorized: true,
            phoneVerified: true, nextSmsSeconds: nil, nextCheckSeconds: nil, expiresInSeconds: nil, account: record.installedAccount)
        enrollment.setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
        let prepared = try publication(tx).publication!
        evidence.setData(prepared.encryptedProfile, key: "frozen-profile", transaction: tx)
        evidence.setData(prepared.accountAttributes, key: "frozen-attributes", transaction: tx)
        if mode == "publication-crash" { crash() }
    }
    crash()
case "dispatch-crash", "dispatch-commit-crash", "ack-crash", "ack-commit-crash":
    try write { tx in
        let record = try publication(tx)
        _ = try BConnectedLocalAccountSetup.transitionPublication(record: record, expected: record,
            step: .attributes, acknowledge: mode.hasPrefix("ack"), tx: tx)
        hidden(tx)
        if !mode.contains("commit") { crash() }
    }
    crash()
case "verify-unpublished", "verify-prepared", "verify-dispatched", "verify-attributes":
    try write { tx in
        hidden(tx)
        let record = try readRecord(tx)
        let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.self, from: evidence.getData("original", transaction: tx)!)
        precondition(record.password == original.password && record.aci.pair == original.aci.pair && record.pni.pair == original.pni.pair)
        precondition(record.registrationRequest == original.registrationRequest && record.keyCommitment == original.keyCommitment)
        if mode == "verify-unpublished" {
            precondition(record.publication == nil && evidence.getData("frozen-profile", transaction: tx) == nil)
            try BConnectedLocalAccountSetup.prepareAccountEntropy(tx: tx, accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), validateNative: validate)
        } else {
            let before = try Int.fetchOne(tx.database, sql: "SELECT total_changes()")!
            let reloaded = try publication(tx)
            try check(Int.fetchOne(tx.database, sql: "SELECT total_changes()") == before)
            let ledger = reloaded.publication!
            precondition(ledger.encryptedProfile == evidence.getData("frozen-profile", transaction: tx))
            precondition(ledger.accountAttributes == evidence.getData("frozen-attributes", transaction: tx))
            let expected: BConnectedEnrollmentRecord.Publication.State = mode == "verify-prepared" ? .prepared : mode == "verify-dispatched" ? .dispatched : .acknowledged
            precondition(ledger.attributesState == expected && ledger.profileState == .prepared && !ledger.complete)
        }
    }
    print("PASS \(mode) fresh process preserves frozen publication bytes, expected dispatch/ack state, native material and readiness barrier")
case "profile-acknowledge":
    try write { tx in
        var record = try publication(tx)
        record = try BConnectedLocalAccountSetup.transitionPublication(record: record, expected: record, step: .profile, acknowledge: false, tx: tx)
        _ = try BConnectedLocalAccountSetup.transitionPublication(record: record, expected: record, step: .profile, acknowledge: true, tx: tx)
        evidence.setData(try counters(tx), key: "original-counters", transaction: tx)
        hidden(tx)
    }
    print("PASS synthetic profile acknowledgement permits next pending key step only")
case "prekeys-crash", "prekeys-commit-crash":
    try write { tx in
        let prepared = try preparePreKeys(tx).preKeyPublication!
        evidence.setData(try JSONEncoder().encode(prepared), key: "frozen-prekeys", transaction: tx)
        hidden(tx)
        if mode == "prekeys-crash" { crash() }
    }
    crash()
case "prekeys-dispatch-crash", "prekeys-dispatch-commit-crash", "prekeys-ack-crash", "prekeys-ack-commit-crash":
    try write { tx in
        let record = try preparePreKeys(tx)
        _ = try BConnectedPreKeySetup.transition(record: record, expected: record, identity: .aci,
            acknowledge: mode.hasPrefix("prekeys-ack"), preKeyStore: preKeys, tx: tx)
        hidden(tx)
        if !mode.contains("commit") { crash() }
    }
    crash()
case "prekeys-finish":
    try write { tx in
        var record = try preparePreKeys(tx)
        record = try BConnectedPreKeySetup.transition(record: record, expected: record, identity: .pni, acknowledge: false, preKeyStore: preKeys, tx: tx)
        _ = try BConnectedPreKeySetup.transition(record: record, expected: record, identity: .pni, acknowledge: true, preKeyStore: preKeys, tx: tx)
        hidden(tx)
    }
    print("PASS synthetic PNI acknowledgement completes key journal while credentials/readiness remain hidden")
case "verify-no-prekeys", "verify-prekeys", "verify-prekeys-dispatched", "verify-prekeys-aci-ack", "verify-prekeys-complete":
    try write { tx in
        let before = try Int.fetchOne(tx.database, sql: "SELECT total_changes()")!
        let originalBytes = enrollment.getData("attempt", transaction: tx)
        let record = try publication(tx)
        if mode == "verify-no-prekeys" {
            precondition(record.preKeyPublication == nil && evidence.getData("frozen-prekeys", transaction: tx) == nil)
            try BConnectedPreKeySetup.validateNative(record, preKeyStore: preKeys, tx: tx)
            try check(counters(tx) == evidence.getData("original-counters", transaction: tx))
        } else {
            let current = try preparePreKeys(tx)
            let ledger = current.preKeyPublication!
            let original = try JSONDecoder().decode(BConnectedEnrollmentRecord.PreKeyPublication.self, from: evidence.getData("frozen-prekeys", transaction: tx)!)
            precondition(ledger.contextHash == original.contextHash)
            for identity in [BConnectedPreKeyIdentity.aci, .pni] {
                let now = ledger.batch(identity), saved = original.batch(identity)
                precondition(now.request == saved.request && now.ec == saved.ec && now.pq == saved.pq)
            }
            let expected: BConnectedEnrollmentRecord.Publication.State = mode == "verify-prekeys" ? .prepared : mode == "verify-prekeys-dispatched" ? .dispatched : .acknowledged
            precondition(ledger.aci.state == expected)
            precondition(ledger.pni.state == (mode == "verify-prekeys-complete" ? .acknowledged : .prepared))
            // An uncertain dispatch has no transition back to prepared and cannot dispatch twice.
            if ledger.aci.state != .prepared {
                do {
                    _ = try BConnectedPreKeySetup.transition(record: current, expected: current, identity: .aci, acknowledge: false, preKeyStore: preKeys, tx: tx)
                    preconditionFailure("repeat key dispatch accepted")
                } catch BConnectedEnrollmentError.immutableConflict {}
            }
        }
        precondition(enrollment.getData("attempt", transaction: tx) == originalBytes)
        try check(Int.fetchOne(tx.database, sql: "SELECT total_changes()") == before)
        hidden(tx)
    }
    print("PASS \(mode) fresh process: exact native private keys/public request bytes, counters and journal preserved with zero writes; no dispatch replay")
case "prekeys-conflicts":
    enum ProbeRollback: Error { case expected }
    for kind in 0..<9 {
        let beforeBytes = try database.read { enrollment.getData("attempt", transaction: DBReadTransaction(database: $0)) }
        do {
            try write { tx in
                var record = try readRecord(tx)
                let first = try LibSignalClient.PreKeyRecord(bytes: record.preKeyPublication!.aci.ec[0])
                switch kind {
                case 0: preKeys.aciStore.removePreKey(in: .oneTime, keyId: first.id, tx: tx)
                case 1: preKeys.aciStore.upsertPreKeyRecord(Data([1]), keyId: first.id, in: .oneTime, isOneTime: true, tx: tx)
                case 2:
                    let key = try LibSignalClient.KyberPreKeyRecord(bytes: record.preKeyPublication!.pni.pq[0])
                    preKeys.pniStore.upsertPreKeyRecord(key.serialize(), keyId: key.id, in: .kyber, isOneTime: false, tx: tx)
                case 3: preKeys.aciStore.upsertPreKeyRecord(Data([1]), keyId: UInt32.max, in: .oneTime, isOneTime: true, tx: tx)
                case 4: _ = PreKeyStoreImpl(for: .aci, preKeyStore: preKeys).allocatePreKeyIds(tx: tx)
                case 5:
                    record.binding = .init(memberId: "00000000-0000-4000-8000-000000000002", challenge: record.binding!.challenge)
                    enrollment.setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
                case 6: break
                case 7:
                    record.observation = .init(operationId: record.operationId!, state: .suspended, registrationAuthorized: false,
                        phoneVerified: true, nextSmsSeconds: nil, nextCheckSeconds: nil, expiresInSeconds: nil, account: record.installedAccount)
                    enrollment.setData(try JSONEncoder().encode(record), key: "attempt", transaction: tx)
                default: try tx.database.execute(sql: "UPDATE model_OWSUserProfile SET profileName = 'Changed'")
                }
                do {
                    if kind == 6 {
                        _ = try BConnectedLocalAccountSetup.preparePublication(tx: tx,
                            configuration: BConnectedPublicationConfiguration(origin: publicationConfiguration.origin, authorityCommitment: Data(repeating: 2, count: 32)),
                            accountKeyStore: AccountKeyStore(backupSettingsStore: .init()), sharePhoneNumber: false, validateNative: validate)
                    } else { _ = try preparePreKeys(tx) }
                    preconditionFailure("changed native/context prerequisite accepted")
                } catch is BConnectedEnrollmentError {}
                throw ProbeRollback.expected
            }
        } catch ProbeRollback.expected {}
        try write { tx in
            precondition(enrollment.getData("attempt", transaction: tx) == beforeBytes)
            _ = try preparePreKeys(tx); hidden(tx)
        }
    }
    print("PASS nine rollback-isolated consumed/changed/foreign key, counter, binding, authority, suspension and profile conflicts rejected; original state remains intact")
default: preconditionFailure("unknown probe mode")
}
