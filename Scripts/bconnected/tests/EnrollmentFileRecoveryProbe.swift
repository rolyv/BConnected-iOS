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
case "verify-uninstalled", "verify-installed", "verify-local", "retry-local":
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
        let local = mode == "verify-local" || mode == "retry-local"
        precondition((record.localSetupReceipt != nil) == local)
        try check(SignalRecipient.fetchCount(native) == (local ? 1 : 0))
    }
    if mode == "retry-local" {
        try write { tx in
            let before = try Int.fetchOne(tx.database, sql: "SELECT total_changes()")!
            let bytes = enrollment.getData("attempt", transaction: tx)
            try BConnectedLocalAccountSetup.prepare(tx: tx, validateNative: validate)
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
default: preconditionFailure("unknown probe mode")
}
